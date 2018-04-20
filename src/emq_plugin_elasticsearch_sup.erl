%%%-------------------------------------------------------------------
%% @doc Supervisor for EMQ Elasticsearch plugin
%% @end
%%%-------------------------------------------------------------------
-module(emq_plugin_elasticsearch_sup).
-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

start_link() ->
  supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
  SupFlags = #{strategy => rest_for_one, intensity => 2, period => 10},
  ChildSpecs = [#{id => emq_plugin_elasticsearch_logger_sup,
                  start => { emq_plugin_elasticsearch_logger_sup, start_link, []},
                  type => supervisor},
                #{id => emq_plugin_elasticsearch,
                  start => {emq_plugin_elasticsearch, start_link, []},
                  restart => permanent,
                  shutdown => 5000,
                  type => worker,
                  modules => [emq_plugin_elasticsearch]}
               ],
  {ok, {SupFlags, ChildSpecs}}.
