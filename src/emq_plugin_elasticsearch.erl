%%%-------------------------------------------------------------------
%% @doc Elasticsearch plugin for EMQ - Hooks API
%% @end
%%%-------------------------------------------------------------------
-module(emq_plugin_elasticsearch).

-include_lib("emqttd/include/emqttd.hrl").

-export([start_link/0
        ,init/1, terminate/2]).

%% Functions to register/unregister hooks
-export([register_hooks/1, unregister_hooks/1]).

%% EMQ hooks callbacks
-export([on_client_connected/3, on_client_disconnected/3,
         on_client_subscribe/4, on_client_unsubscribe/4,
         on_session_created/3, on_session_terminated/4,
         on_session_subscribed/4, on_session_unsubscribed/4,
         on_message_publish/2, on_message_delivered/4, on_message_acked/4]).



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
  'client.connected' => fun ?MODULE:on_client_connected/3,
  'client.disconnected' => fun ?MODULE:on_client_disconnected/3,
  'client.subscribe' => fun ?MODULE:on_client_subscribe/4,
  'client.unsubscribe' => fun ?MODULE:on_client_unsubscribe/4,
  'session.created' => fun ?MODULE:on_session_created/3,
  'session.terminated' => fun ?MODULE:on_session_terminated/4,
  'session.subscribed' => fun ?MODULE:on_session_subscribed/4,
  'session.unsubscribed' => fun ?MODULE:on_session_unsubscribed/4,
  'message.publish' => fun ?MODULE:on_message_publish/2,
  'message.delivered' => fun ?MODULE:on_message_delivered/4,
  'message.acked' => fun ?MODULE:on_message_acked/4
 }.

%%%-------------------------------------------------------------------
%% @doc Handles hook registrations when loading the plugin
%% @end
%%%-------------------------------------------------------------------
register_hooks(Env) ->
  EnabledEvents = proplists:get_value(enabled_events, Env, []),
  AllHooks = all_hooks(),
  lists:map(fun(E)->
                HookFun = maps:get(E, AllHooks),
                ExtraArgs = [get_log_fields(E, Env)],
                ok = emqttd:hook(E, HookFun, ExtraArgs)
            end, EnabledEvents),
  ok.

%%%-------------------------------------------------------------------
%% @doc Handles hook deregistrations when unloading the plugin
%% @end
%%%-------------------------------------------------------------------
unregister_hooks(Env) ->
  EnabledEvents = proplists:get_value(enabled_events, Env, []),
  AllHooks = all_hooks(),
  lists:map(fun(E) ->
                HookFun = maps:get(E, AllHooks),
                emqttd:unhook(E, HookFun)
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
  #mqtt_message{
     id = Id
    ,pktid = PktId
    ,from = From
    ,topic = Topic
    ,qos = Qos
    % flags ignored since retain, dup, sys contain same info.
    ,retain = Retain
    ,dup = Dup
    ,sys = Sys
    ,payload = Payload
    ,timestamp = ErlTimestamp
    } = Message,
  #{
     dup => Dup
    ,from => format_from(From)
    ,id => base64:encode(Id)
    ,payload => Payload
    ,pktid => PktId
    ,qos => Qos
    ,retain => Retain
    ,sys => Sys
    ,msg_timestamp => timestamp(ErlTimestamp)
    ,topic => Topic
    ,size => erlang:size(Payload)
  }.


%%% Format helpers
%%  Some fields may not be in an acceptable format for jsx, used by esio.
%%  Helpers to convert offending fields into acceptable formats.

format_peername({Addr,Port})->
  #{address => erlang:list_to_binary(inet:ntoa(Addr)), port => Port}.

format_from({ClientId, Username})->
  #{client_id => ClientId, username => Username}.

format_reason(Reason) when is_atom(Reason) -> Reason;
format_reason(Reason) when is_binary(Reason) -> Reason;
format_reason(Reason) ->
  erlang:iolist_to_binary(io_lib:format("~P", [Reason, 20])).

%%& Hooks
%%  The names should be self explanatory.

on_client_connected(ConnAck, Client, Keys) ->
  #mqtt_client{
     clean_sess = CleanSession
    ,client_id = ClientId
    ,connected_at = ConnectedAt
    ,keepalive = Keepalive
    ,peername = Peername
    ,proto_ver = ProtoVer
    ,username = Username
    ,will_topic = WillTopic
  } = Client,
  % TODO: Consider ws_initial_headers
  %  Document reason for exclusion or inclusion after deciding.
  Log = #{
     event => <<"client_connected">>
    ,clean_sess => CleanSession
    ,client_id => ClientId
    ,connack => ConnAck
    ,connected_at => timestamp(ConnectedAt)
    ,keepalive => Keepalive
    ,peername => format_peername(Peername)
    ,proto_ver => ProtoVer
    ,timestamp => timestamp()
    ,username => Username
    ,will_topic => WillTopic
  },
  log_to_es(maps:with(Keys, Log)),
  {ok, Client}.

on_client_disconnected(Reason, Client, Keys) ->
  #mqtt_client{
     clean_sess = CleanSession
    ,client_id = ClientId
    ,connected_at = ConnectedAt
    ,keepalive = Keepalive
    ,peername = Peername
    ,proto_ver = ProtoVer
    ,username = Username
    ,will_topic = WillTopic
  } = Client,
  % TODO: Consider ws_initial_headers
  %  Document reason for exclusion or inclusion after deciding.
  Log = #{
     event => <<"client_disconnected">>
    ,clean_sess => CleanSession
    ,client_id => ClientId
    ,connected_at => timestamp(ConnectedAt)
    ,keepalive => Keepalive
    ,peername => format_peername(Peername)
    ,proto_ver => ProtoVer
    ,reason => format_reason(Reason)
    ,timestamp => timestamp()
    ,username => Username
    ,will_topic => WillTopic
  },
  log_to_es(maps:with(Keys, Log)),
  ok.

on_client_subscribe(ClientId, Username, TopicTable, Keys) ->
  Log = #{
     event => <<"client_subscribe">>
    ,client_id => ClientId
    ,timestamp => timestamp()
    ,topics => TopicTable
    ,username => Username
   },
  log_to_es(maps:with(Keys, Log)),
  {ok, TopicTable}.

on_client_unsubscribe(ClientId, Username, TopicTable, Keys) ->
  Log = #{
     event => <<"client_unsubscribe">>
    ,client_id => ClientId
    ,timestamp => timestamp()
    ,topics => TopicTable
    ,username => Username
   },
  log_to_es(maps:with(Keys, Log)),
  {ok, TopicTable}.

on_session_created(ClientId, Username, Keys) ->
  Log = #{
     event => <<"session_created">>
    ,client_id => ClientId
    ,timestamp => timestamp()
    ,username => Username
   },
  log_to_es(maps:with(Keys, Log)).

on_session_subscribed(ClientId, Username, {Topic, Opts}, Keys) ->
  Log = #{
     event => <<"session_subscribed">>
    ,client_id => ClientId
    ,options => Opts
    ,timestamp => timestamp()
    ,topic => Topic
    ,username => Username
   },
  log_to_es(maps:with(Keys, Log)),
  {ok, {Topic, Opts}}.

on_session_unsubscribed(ClientId, Username, {Topic, Opts}, Keys) ->
  Log = #{
     event => <<"session_unsubscribed">>
    ,client_id => ClientId
    ,options => Opts
    ,timestamp => timestamp()
    ,topic => Topic
    ,username => Username
   },
  log_to_es(maps:with(Keys, Log)),
  ok.

on_session_terminated(ClientId, Username, Reason, Keys) ->
  Log = #{
     event => <<"session_terminated">>
    ,client_id => ClientId
    ,reason => format_reason(Reason)
    ,timestamp => timestamp()
    ,username => Username
   },
  log_to_es(maps:with(Keys, Log)).

on_message_publish(Message = #mqtt_message{topic = <<"$SYS/", _/binary>>}, _Env) ->
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

on_message_delivered(ClientId, Username, Message, Keys) ->
  Log = maps:merge(unpack_message(Message), #{
     event => <<"message_delivered">>
    ,client_id => ClientId
    ,timestamp => timestamp()
    ,username => Username
   }),
  log_to_es(maps:with(Keys, Log)),
  {ok, Message}.

on_message_acked(ClientId, Username, Message, Keys) ->
  Log = maps:merge(unpack_message(Message), #{
     event => <<"message_acked">>
    ,client_id => ClientId
    ,timestamp => timestamp()
    ,username => Username
   }),
  log_to_es(maps:with(Keys, Log)),
  {ok, Message}.

