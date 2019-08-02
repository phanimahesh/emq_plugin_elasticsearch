%%%-------------------------------------------------------------------
%% @doc Elasticsearch plugin for EMQ - Hooks API
%% @end
%%%-------------------------------------------------------------------
-module(emq_plugin_elasticsearch).

-include_lib("emqx/include/emqx.hrl").

-export([start_link/0
        ,init/1, terminate/2]).

%% Functions to register/unregister hooks
-export([register_hooks/1, unregister_hooks/1]).

%% EMQ hooks callbacks
-export([on_client_connected/4, on_client_disconnected/3,
         on_client_subscribe/3, on_client_unsubscribe/3
%         on_session_created/3, on_session_terminated/4,
%         on_session_subscribed/4, on_session_unsubscribed/4,
%         on_message_publish/2, on_message_delivered/3, on_message_acked/3
        ]).

start_link() ->
  gen_server:start_link(?MODULE, [], []).

init([]) ->
  Env = application:get_all_env(),
  ok = register_hooks(Env),
  {ok, []}.

terminate(_Reason, _State) ->
  Env = application:get_all_env(),
  ok = unregister_hooks(Env).

all_hooks() ->
  #{
  'client.connected' => fun ?MODULE:on_client_connected/4,
  'client.disconnected' => fun ?MODULE:on_client_disconnected/3,
  'client.subscribe' => fun ?MODULE:on_client_subscribe/3,
  'client.unsubscribe' => fun ?MODULE:on_client_unsubscribe/3
  % 'session.created' => fun ?MODULE:on_session_created/3,
  % 'session.resumed' => fun ?MODULE:on_session_resumed/3,
  % 'session.terminated' => fun ?MODULE:on_session_terminated/3,
  % 'session.subscribed' => fun ?MODULE:on_session_subscribed/4,
  % 'session.unsubscribed' => fun ?MODULE:on_session_unsubscribed/4,
  % 'message.publish' => fun ?MODULE:on_message_publish/2,
  % 'message.deliver' => fun ?MODULE:on_message_deliver/3,
  % 'message.acked' => fun ?MODULE:on_message_acked/3
  % 'message.dropped' => fun ?MODULE:on_message_dropped/3
 }.

%%%-------------------------------------------------------------------
%% @doc Handles hook registrations when loading the plugin
%% @end
%%%-------------------------------------------------------------------
register_hooks(Env) ->
  AllHooks = all_hooks(),
  % EnabledEvents = proplists:get_value(enabled_events, Env, []),
  EnabledEvents = maps:keys(AllHooks),
  lists:map(fun(E)->
                HookFun = maps:get(E, AllHooks),
                ExtraArgs = [get_log_fields(E, Env)],
                ok = emqx:hook(E, HookFun, ExtraArgs)
            end, EnabledEvents),
  ok.

%%%-------------------------------------------------------------------
%% @doc Handles hook deregistrations when unloading the plugin
%% @end
%%%-------------------------------------------------------------------
unregister_hooks(_Env) ->
  AllHooks = all_hooks(),
  % EnabledEvents = proplists:get_value(enabled_events, Env, []),
  EnabledEvents = maps:keys(AllHooks),
  lists:map(fun(E) ->
                HookFun = maps:get(E, AllHooks),
                emqx:unhook(E, HookFun)
            end, EnabledEvents).

%%%-------------------------------------------------------------------
%% @private
%% @doc Returns the fields to be logged for a given event type
%% @end
%%%-------------------------------------------------------------------
get_log_fields(Type, Env) ->
  LogFields = proplists:get_value(log_fields, Env, []),
  proplists:get_value(Type, LogFields, []) ++ [event, timestamp].

%%%-------------------------------------------------------------------
%% @private
%% @doc Handles logging to elasticsearch
%% @end
%%%-------------------------------------------------------------------
log_to_es(Document) ->
  emq_plugin_elasticsearch_logger:log(Document).

%%%-------------------------------------------------------------------
%% @private
%% @doc Helper to extract value from a keyword list
%% @end
%%%-------------------------------------------------------------------
kw_get(Key, KWList) ->
  {Key, Val} = lists:keyfind(Key, 1, KWList),
  Val.

%%%-------------------------------------------------------------------
%% @private
%% @doc Returns current Erlang System Time in milliseconds
%%
%%  This was chosen to match Web Events API, for no particular reason.
%%  https://developer.mozilla.org/en-US/docs/Web/API/Event/timeStamp
%% @end
%%%-------------------------------------------------------------------
timestamp() ->
  erlang:system_time(milli_seconds).

%%%-------------------------------------------------------------------
%% @private
%% @doc Converts given erlang:timestamp() into milliseconds since
%%  epoch.
%% @end
%%%-------------------------------------------------------------------
timestamp({MegaSecs, Secs, MicroSecs}) ->
  (MegaSecs * 1000000 + Secs)*1000 + (MicroSecs div 1000).

%%%-------------------------------------------------------------------
%% @private
%% @doc Unpacks a mqtt_message record into an erlang map.
%% @end
%%%-------------------------------------------------------------------
unpack_message(Message) ->
  #message{
     id = Id
    ,qos = Qos
    ,from = From
    ,flags = Flags
    ,headers = Headers
    ,topic = Topic
    ,payload = Payload
    ,timestamp = ErlTimestamp
    } = Message,
  #{
     id => case Id of undefined -> <<"undefined">>; Id -> base64:encode(Id) end
    ,qos => Qos
    ,from => From
    ,dup => maps:get(dup, Flags)
    ,retain => maps:get(retain, Flags)
    ,headers => Headers
    ,topic => Topic
    ,payload => Payload
    ,size => erlang:size(Payload)
    ,msg_timestamp => timestamp(ErlTimestamp)
  }.


%%% Format helpers
%%  Some fields may not be in an acceptable format for jsx, used by esio.
%%  Helpers to convert offending fields into acceptable formats.

format_peername({Addr,Port})->
  #{address => erlang:list_to_binary(inet:ntoa(Addr)), port => Port}.

format_from({ClientId, Username})->
  #{client_id => ClientId, username => Username}.

format_reason(Reason) when is_integer(Reason) -> Reason;
format_reason(Reason) when is_atom(Reason) -> Reason;
format_reason(Reason) when is_binary(Reason) -> Reason;
format_reason(Reason) ->
  erlang:iolist_to_binary(io_lib:format("~P", [Reason, 20])).

format_credentials(Credentials) ->
  maps:update_with(peername, fun format_peername/1, Credentials).

%%& Hooks
%%  The names should be self explanatory.

  %%  Structure of ConnAttrs:
  %%     #{ zone => Zone
  %%      , client_id => ClientId
  %%      , username => Username
  %%      , peername => Peername
  %%      , peercert => Peercert
  %%      , proto_ver => ProtoVer
  %%      , proto_name => ProtoName
  %%      , clean_start => CleanStart
  %%      , keepalive => Keepalive
  %%      , is_bridge => IsBridge
  %%      , connected_at => ConnectedAt
  %%      , conn_mod => ConnMod
  %%      , credentials => Credentials
  %%      }

on_client_connected(_Credentials, ConnAck, ConnAttrs, Keys) ->
  Peername = maps:get(peername, ConnAttrs),
  ConnectedAt = maps:get(connected_at, ConnAttrs),
  SafeAttrs = [zone, client_id, username,
               proto_ver, proto_name],
  ConnAttrsMap = maps:with(SafeAttrs, ConnAttrs),
  Log = maps:merge(ConnAttrsMap, #{
     event => <<"client_connected">>
    ,connack => ConnAck
    ,connected_at => timestamp(ConnectedAt)
    ,peername => format_peername(Peername)
    ,timestamp => timestamp()
  }),
  log_to_es(maps:with(Keys, Log)),
  ok.

on_client_disconnected(Credentials, ReasonCode, Keys) ->
  Creds = format_credentials(Credentials),
  Log = maps:merge(Creds, #{
     event => <<"client_disconnected">>
    ,reason => format_reason(ReasonCode)
    ,timestamp => timestamp()
  }),
  log_to_es(maps:with(Keys, Log)),
  ok.

on_client_subscribe(Credentials, TopicFilters, Keys) ->
  Creds = format_credentials(Credentials),
  Log = maps:merge(Creds, #{
     event => <<"client_subscribe">>
    ,timestamp => timestamp()
    ,topics => TopicFilters
   }),
  log_to_es(maps:with(Keys, Log)),
  {ok, TopicFilters}.

on_client_unsubscribe(Credentials, TopicFilters, Keys) ->
  Creds = format_credentials(Credentials),
  Log = maps:merge(Creds, #{
     event => <<"client_unsubscribe">>
    ,timestamp => timestamp()
    ,topics => TopicFilters
   }),
  log_to_es(maps:with(Keys, Log)),
  {ok, TopicFilters}.

%% XXX: Lots of stuff in sessInfo. look at emqx_session:info/1
on_session_created(#{client_id := ClientId}, SessInfo, Keys) ->
  Username = kw_get(username, SessInfo),
  Log = #{
     event => <<"session_created">>
    ,client_id => ClientId
    ,timestamp => timestamp()
    ,username => Username
   },
  log_to_es(maps:with(Keys, Log)).

on_session_resumed(#{client_id := ClientId}, SessInfo, Keys) ->
  Username = kw_get(username, SessInfo),
  Log = #{
     event => <<"session_resumed">>
    ,client_id => ClientId
    ,timestamp => timestamp()
    ,username => Username
   },
  log_to_es(maps:with(Keys, Log)).

on_session_subscribed(#{client_id := ClientId}, Topic, Opts, Keys) ->
  Log = #{
     event => <<"session_subscribed">>
    ,client_id => ClientId
    ,options => Opts
    ,timestamp => timestamp()
    ,topic => Topic
   },
  log_to_es(maps:with(Keys, Log)),
  ok.

on_session_unsubscribed(#{client_id := ClientId}, Topic, Opts, Keys) ->
  Log = #{
     event => <<"session_unsubscribed">>
    ,client_id => ClientId
    ,options => Opts
    ,timestamp => timestamp()
    ,topic => Topic
   },
  log_to_es(maps:with(Keys, Log)),
  ok.

on_session_terminated(#{client_id := ClientId}, ReasonCode, Keys) ->
  Log = #{
     event => <<"session_terminated">>
    ,client_id => ClientId
    ,reason => format_reason(ReasonCode)
    ,timestamp => timestamp()
   },
  log_to_es(maps:with(Keys, Log)).

on_message_publish(Message = #message{topic = <<"$SYS/", _/binary>>}, _Env) ->
  % Sys topics are deliberately ignored.
  % I don't know what crazy use case will require it,
  % but I'm currently assuming it doesn't exist unless shown otherwise.
  {ok, Message};

on_message_publish(Message, Keys) ->
  % It would probably be crazy to log all messages
  % But I won't judge. It's possible, if you really want to.
  Log = maps:merge(unpack_message(Message), #{
     event => <<"message_published">>
    ,timestamp => timestamp()
   }),
  log_to_es(maps:with(Keys, Log)),
  {ok, Message}.

on_message_delivered(#{client_id := ClientId}, Message, Keys) ->
  Log = maps:merge(unpack_message(Message), #{
     event => <<"message_delivered">>
    ,client_id => ClientId
    ,timestamp => timestamp()
   }),
  log_to_es(maps:with(Keys, Log)),
  {ok, Message}.

on_message_acked(#{client_id := ClientId}, Message, Keys) ->
  Log = maps:merge(unpack_message(Message), #{
     event => <<"message_acked">>
    ,client_id => ClientId
    ,timestamp => timestamp()
   }),
  log_to_es(maps:with(Keys, Log)),
  {ok, Message}.

on_message_dropped(_By, #message{topic = <<"$SYS/", _/binary>>}, _Keys) ->
    ok;
on_message_dropped(#{node := Node}, Message, Keys) ->
  Log = maps:merge(unpack_message(Message), #{
     event => <<"message_dropped">>
    ,timestamp => timestamp()
    ,node => Node
   }),
  log_to_es(maps:with(Keys, Log));
on_message_dropped(#{client_id := ClientId}, Message, Keys) ->
  Log = maps:merge(unpack_message(Message), #{
     event => <<"message_dropped">>
    ,timestamp => timestamp()
    ,client_id => ClientId
   }),
  log_to_es(maps:with(Keys, Log)).
