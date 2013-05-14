-module(ws_server).
-behavior(cowboy_websocket_handler).

-include_lib("eunit/include/eunit.hrl").

-export([start/2, start_link/2, reset_msgs/1, handlers/0, stop/0]).
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
	case lists:member(?MODULE, ets:all()) of
		true ->
			ok;
		false ->
			ets:new(?MODULE, [named_table, public, set])
	end,
	application:start(crypto),
	%application:start(ranch),
	%application:start(cowboy),
	start_app(cowboy),
	Dispatch = cowboy_router:compile([{'_', [
		{Url, ?MODULE, []},
		{<<"/">>, ?MODULE, [index]},
		{<<"/favicon.ico">>, ?MODULE, [404]},
		{<<"/[...]">>, ?MODULE, [put]}
	]}]),
	cowboy:start_http(?MODULE, 1, [{port, Port}], [{env, [{dispatch, Dispatch}]}]).

stop() ->
	cowboy:stop_listener(?MODULE).

reset_msgs(WsHandler) ->
	[{_WsHandler, Q}] = ets:lookup(?MODULE, WsHandler),
	ets:insert(?MODULE, {WsHandler, []}),
	lists:reverse(Q).

handlers() ->
	% good time as any to clean out dead handlers
	All = ets:foldl(fun({P, _}, Acc) ->
		[P | Acc]
	end, [], ?MODULE),
	AliveFold = fun(P, Acc) ->
		case is_process_alive(P) of
			false ->
				ets:delete(?MODULE, P),
				Acc;
			true ->
				[P | Acc]
		end
	end,
	lists:foldl(AliveFold, [], All).

%% cowboy handler stuff

init(_Proto, Req, [Mode]) ->
	?debugFmt("mode: ~p", [Mode]),
	{ok, Req, Mode};
init(_Protocol, _Req, _Opts) ->
	{upgrade, protocol, cowboy_websocket}.

handle(Req, index) ->
	{ok, Req1} = cowboy_req:reply(200, [{<<"content-type">>, <<"text/plain">>}], <<"a page for you sir">>, Req),
	{ok, Req1, index};
handle(Req, 404) ->
	{ok, Req1} = cowboy_req:reply(404, [], <<>>, Req),
	{ok, Req1, 404};
handle(Req, put) ->
	{Path, Req1} = cowboy_req:path_info(Req),
	ets:foldl(fun({P, _Gots}, _) ->
		P ! {send, Path}
	end, undefined, ?MODULE),
	{ok, Req2} = cowboy_req:reply(204, [], <<>>),
	{ok, Req2, put}.

websocket_init(_TransportName, Req, _Opt) ->
	?debugMsg("ws init"),
	ets:insert(?MODULE, {self(), []}),
	{ok, Req, undefined}.

websocket_handle({text, Msg}, Req, State) ->
	?debugFmt("got text ~p", [Msg]),
	[{Me, Msgs}] = ets:lookup(?MODULE, self()),
	ets:insert(?MODULE, {Me, [Msg | Msgs]}),
	{reply, {text, <<"okie: ", Msg/binary>>}, Req, State};
websocket_handle(Msg, Req, State) ->
	?debugFmt("der, okay: ~p", [Msg]),
	{ok, Req, State}.

websocket_info({send, Msg}, Req, State) ->
	?debugMsg("sending!"),
	{reply, {text, Msg}, Req, State};
websocket_info(Info, Req, State) ->
	?debugFmt("ws info: ~p", [Info]),
	{ok, Req, State}.

websocket_terminate(Reason, _Req, _State) ->
	?debugFmt("ws termiant: ~p", [Reason]),
	ok.

terminate(Reason,_,_) ->
	?debugFmt("other terminate: ~p", [Reason]),
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




