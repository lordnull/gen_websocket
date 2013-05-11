-module(ws_server).
-behavior(cowboy_websocket_handler).

-include_lib("eunit/include/eunit.hrl").

-export([start/2, start_link/2]).
-export([init/3, handle/2, websocket_init/3, websocket_handle/3,
	websocket_info/3, websocket_terminate/3, terminate/3]).

%% api

start_link(Url, Port) ->
	case start(Url, Port) of
		{ok, Pid} ->
			link(Pid),
			{ok, Pid};
		Else ->
			Else
	end.

start(Url, Port) ->
	application:start(crypto),
	%application:start(ranch),
	%application:start(cowboy),
	start_app(cowboy),
	Dispatch = cowboy_router:compile([{'_', [
		{Url, ?MODULE, []},
		{<<"/">>, ?MODULE, [index]}
	]}]),
	cowboy:start_http(?MODULE, 1, [{port, Port}], [{env, [{dispatch, Dispatch}]}]).

%% cowboy handler stuff

init(_Proto, Req, [index]) ->
	?debugMsg("static serving"),
	{ok, Req, index};
init(_Protocol, _Req, _Opts) ->
	{upgrade, protocol, cowboy_websocket}.

handle(Req, index) ->
	{ok, Req1} = cowboy_req:reply(200, [{<<"content-type">>, <<"text/plain">>}], <<"a page for you sir">>, Req),
	{ok, Req1, index}.

websocket_init(_TransportName, Req, _Opt) ->
	{ok, Req, undefined}.

websocket_handle({text, Msg}, Req, State) ->
	{reply, {text, <<"okie: ", Msg/binary>>}, Req, State};
websocket_handle(_Msg, Req, State) ->
	{ok, Req, State}.

websocket_info({send, Msg}, Req, State) ->
	{reply, {text, Msg}, Req, State};
websocket_info(_Info, Req, State) ->
	{ok, Req, State}.

websocket_terminate(_Reason, _Req, _State) ->
	ok.

terminate(_,_,_) ->
	ok.

%% internal

start_app(AppName) ->
	case application:start(AppName) of
		ok ->
			ok;
		{error, {already_started, AppName}} ->
			ok;
		{error, {not_started, Dep}} ->
			ok = start_app(Dep),
			start_app(AppName)
	end.




