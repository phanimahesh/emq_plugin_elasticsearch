-module(emq_plugin_elasticsearch_logger).

% Gen server callbacks
-export([start_link/0
        ,init/1, terminate/2
        ,handle_info/2, handle_cast/2
        ]).

% Public API
-export([log/1]).

%%%-------------------------------------------------------------------
%% @doc Logs supplied document to elasticsearch
%%  The server and urn are taken from application's environment
%% @end
%%%-------------------------------------------------------------------
log(Doc) ->
  gen_server:cast(?MODULE, {log, Doc}).

%%%-------------------------------------------------------------------
%% Gen server callbacks
%%%-------------------------------------------------------------------
start_link() -> 
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
  {ok, State} = create_bulk_socket(),
  Env = application:get_all_env(),
  ok = emq_plugin_elasticsearch:register_hooks(Env),
  {ok, State}.

terminate(_Reason, {Sock, Ref}) ->
  esio:close(Sock),
  erlang:demonitor(Ref, [flush]),
  Env = application:get_all_env(),
  ok = emq_plugin_elasticsearch:unregister_hooks(Env).

% When the socket closes unexpectedly, re-establish connection.
handle_info({'DOWN', Ref, process, Pid, Reason}, {_Sock, Ref}) ->
  io:format("ES bulk socket ~w closed for reason: ~p~n", [Pid, Reason]),
  {ok, State} = create_bulk_socket(),
  {noreply, State};

handle_info({'$pipe', _Pid, ok}, State) ->
  % esio:put_ calls are causing one message each, probably.
  % The pid is the same in all mesages. This message isn't useful unless
  % we want to count how many have been acknowledged.
  {noreply, State};

handle_info(Info, State) ->
  io:format("Unhandled info: ~p~n", [Info]),
  {noreply, State}.

handle_cast({log, Doc}, {Sock, _Ref} = State) ->
  Id = uuid:to_string(uuid:uuid1()),
  esio:put_(Sock, "urn:es:mqtt:events:" ++ Id, Doc),
  {noreply, State}.

%%%-------------------------------------------------------------------
%% Internal helpers
%%%-------------------------------------------------------------------
create_bulk_socket() ->
  % Set up a bulk esio socket
  {ok, ESUrl} = application:get_env(es_url),
  {ok, Sock} = esio:socket(ESUrl, [bulk]),
  Ref = erlang:monitor(process, Sock),
  {ok, {Sock, Ref}}.
