-module(emq_plugin_elasticsearch_logger).

% Gen server callbacks
-export([start_link/0, start_link/1
        ,init/1, terminate/2
        ,handle_info/2, handle_cast/2
        ]).

% Public API
-export([log/1]).

-define(POOL, es_logger_pool).

%%%-------------------------------------------------------------------
%% @doc Logs supplied document to elasticsearch
%%  The server and urn are taken from application's environment
%% @end
%%%-------------------------------------------------------------------
log(Doc) ->
  Worker = poolboy:checkout(?POOL),
  gen_server:cast(Worker, {log, Doc}).

%%%-------------------------------------------------------------------
%% Gen server callbacks
%%%-------------------------------------------------------------------
start_link() -> 
  gen_server:start_link(?MODULE, [], []).

start_link(_Args) -> 
  gen_server:start_link(?MODULE, [], []).

init([]) ->
  {ok, State} = create_bulk_socket(),
  {ok, State}.

terminate(_Reason, {Sock, Ref}) ->
  esio:close(Sock),
  erlang:demonitor(Ref, [flush]).

% When the socket closes unexpectedly, re-establish connection.
handle_info({'DOWN', Ref, process, Pid, Reason}, {_Sock, Ref}) ->
  io:format("ES bulk socket ~w closed for reason: ~p~n", [Pid, Reason]),
  {ok, State} = create_bulk_socket(),
  {noreply, State};

handle_info({'$pipe', _Pid, _}, State) ->
  % esio:put_ calls return one messge each.
  poolboy:checkin(?POOL, self()),
  {noreply, State};

handle_info(Info, State) ->
  io:format("Unhandled info: ~p~n", [Info]),
  {noreply, State}.

% handle_call({log, Doc}, _From, {Sock, _Ref} = State) ->
handle_cast({log, Doc}, {Sock, _Ref} = State) ->
  Id = uuid:to_string(uuid:uuid1()),
  esio:put_(Sock, {urn, <<"events">>, Id}, Doc),
  {noreply, State}.

%%%-------------------------------------------------------------------
%% Internal helpers
%%%-------------------------------------------------------------------
create_bulk_socket() ->
  % Set up a bulk esio socket
  {ok, ESUrl} = application:get_env(es_url),
  {ok, Sock} = esio:socket(ESUrl, [bulk, {n, 2000}, {active, true}]),
  Ref = erlang:monitor(process, Sock),
  {ok, {Sock, Ref}}.
