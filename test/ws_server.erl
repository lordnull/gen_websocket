-module(ws_server).
-behavior(cowboy_websocket_handler).

-include_lib("eunit/include/eunit.hrl").

-export([start/2, start_link/2, reset_msgs/1, handlers/0, stop/0,
	send/1, send/2, send/3, headers/1, header/2]).
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
	spawn(fun ets_holder/0),
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

ets_holder() ->
	case lists:member(?MODULE, ets:all()) of
		true ->
			ok;
		false ->
			ets:new(?MODULE, [named_table, public, set]),
			receive after infinity -> ok end
	end.

stop() ->
	cowboy:stop_listener(?MODULE).

reset_msgs(WsHandler) ->
	[{_WsHandler, Q}] = ets:lookup(?MODULE, WsHandler),
	ets:insert(?MODULE, {WsHandler, []}),
	?debugFmt("resetting message q of ~p. It had: ~p", [WsHandler, Q]),
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

send(Msg) when is_binary(Msg) ->
	send({text, Msg});
send(Msg) ->
	ets:foldl(fun({P, _}, Acc) ->
		send(P, Msg),
		[P | Acc]
	end, [], ?MODULE).

send(Handler, Msg) when is_binary(Msg) ->
	send(Handler, {text, Msg});
send(Handler, {Type, Msg}) ->
	Handler ! {send, Type, Msg},
	ok.

send(Handler, Type, Msg) ->
	send(Handler, {Type, Msg}).

headers(Handler) ->
	gen_server:call(Handler, headers).

header(Handler, Header) ->
	gen_server:call(Handler, {header, Header}).

%% cowboy handler stuff

init(_Proto, Req, [Mode]) ->
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
		send(P, Path)
	end, undefined, ?MODULE),
	{ok, Req2} = cowboy_req:reply(204, [], <<>>),
	{ok, Req2, put}.

websocket_init(_TransportName, Req, _Opt) ->
	ets:insert(?MODULE, {self(), []}),
	{ok, Req, pong}.

websocket_handle({pong, _Msg}, Req, State) ->
	[{Me, Msgs}] = ets:lookup(?MODULE, self()),
	?debugMsg("got a pong"),
	ets:insert(?MODULE, {Me, [pong | Msgs]}),
	{ok, Req, State};
websocket_handle({text, Msg}, Req, State) ->
	?debugMsg("got a somethign text"),
	[{Me, Msgs}] = ets:lookup(?MODULE, self()),
	ets:insert(?MODULE, {Me, [Msg | Msgs]}),
	{ok, Req, State};
	%{reply, {text, <<"okie: ", Msg/binary>>}, Req, State};
websocket_handle(Msg, Req, State) ->
	?debugFmt("discarding ~p", [Msg]),
	{ok, Req, State}.

websocket_info({send, Type, Msg}, Req, State) ->
	{reply, {Type, Msg}, Req, State};
websocket_info({'$gen_call', From, headers}, Req, State) ->
	{Headers, Req2} = cowboy_req:headers(Req),
	gen_server:reply(From, {ok, Headers}),
	{ok, Req2, State};
websocket_info({'$gen_call', From, {header, Header}}, Req, State) ->
	{Val, Req2} = cowboy_req:header(Header, Req),
	gen_server:reply(From, {ok, Val}),
	{ok, Req2, State};
websocket_info(Info, Req, State) ->
	?debugFmt("no idea what to do with ~p", [Info]),
	{ok, Req, State}.

websocket_terminate(Reason, _Req, _State) ->
	ok.

terminate(Reason,_,_) ->
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




