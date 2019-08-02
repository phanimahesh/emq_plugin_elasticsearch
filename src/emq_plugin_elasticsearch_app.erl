-module(emq_plugin_elasticsearch_app).
-behaviour(application).

-define(APP, emq_plugin_elasticsearch).

-emqx_plugin(?MODULE).

%% Application callbacks
-export([start/2, stop/1]).

%% Application API
start(_StartType, _StartArgs) ->
  emq_plugin_elasticsearch_sup:start_link().

stop(_State) ->
    ok.

