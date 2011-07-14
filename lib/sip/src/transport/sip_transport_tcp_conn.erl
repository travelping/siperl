%%%----------------------------------------------------------------
%%% @author Ivan Dubrov <wfragg@gmail.com>
%%% @doc
%%%
%%% @end
%%% @copyright 2011 Ivan Dubrov
%%%----------------------------------------------------------------
-module(sip_transport_tcp_conn).

-behaviour(gen_server).

%%-----------------------------------------------------------------
%% Exports
%%-----------------------------------------------------------------

%% API
-export([send/2]).

%% Server callbacks
-export([start_link/1]).
-export([init/1, terminate/2, code_change/3]).
-export([handle_info/2, handle_call/3, handle_cast/2]).

%%-----------------------------------------------------------------
%% Include files
%%-----------------------------------------------------------------
-include_lib("../sip_common.hrl").
-include_lib("sip.hrl").

-define(SERVER, ?MODULE).

-record(state, {socket, remote, parse_state = none}).

%%-----------------------------------------------------------------
%% External functions
%%-----------------------------------------------------------------
-spec start_link(#sip_destination{} | inet:socket()) -> {ok, pid()}.
start_link(Remote) ->
    gen_server:start_link(?MODULE, Remote, []).

%% @doc
%% Send SIP message through given connection.
%% @end
-spec send(pid(), #sip_message{}) -> {ok, pid()} | {error, Reason :: term()}.
send(Pid, Message) when is_pid(Pid), is_record(Message, sip_message) ->
    gen_server:call(Pid, {send, Message}).

%%-----------------------------------------------------------------
%% Server callbacks
%%-----------------------------------------------------------------

%% @private
-spec init(inet:socket() | #sip_destination{}) -> {ok, #state{}}.
init(Remote)
  when is_record(Remote, sip_destination) ->
    % New connection
    To = Remote#sip_destination.address,
    Port = Remote#sip_destination.port,
    % FIXME: Opts...
    {ok, Socket} = gen_tcp:connect(To, Port, [binary, {active, false}]),
    init(Socket);

init(Socket) ->
    % RFC3261 Section 18
    % These connections are indexed by the tuple formed from the address,
    % port, and transport protocol at the far end of the connection.
    {ok, {RemoteAddress, RemotePort}} = inet:peername(Socket),
    Remote = #sip_destination{transport = tcp, address = RemoteAddress, port = RemotePort},

    % Register itself
    %gproc:add_local_property({to, Remote}, Local),

    % Enable one time delivery
    ok = inet:setopts(Socket, [{active, once}]),
    {ok, #state{socket = Socket, remote = Remote}}.

%% @private
-spec handle_info({tcp, inet:socket(), binary()} | tcp_closed | term(), #state{}) ->
          {noreply, #state{}} | {stop, normal, #state{}} | {stop, {unexpected, _}, #state{}}.
handle_info({tcp, _Socket, Packet}, State) ->
    {ok, ParseState, Msgs} = sip_message:parse_stream(Packet, State#state.parse_state),

    % Dispatch to transport layer
    Dispatch =
        fun (Msg) ->
                 case sip_message:is_request(Msg) of
                     true -> sip_transport:dispatch_request(State#state.remote, self(), Msg);
                     false -> sip_transport:dispatch_response(State#state.remote, self(), Msg)
                 end
        end,
    lists:foreach(Dispatch, Msgs),

    ok = inet:setopts(State#state.socket, [{active, once}]),
    {noreply, State#state{parse_state = ParseState}};

handle_info({tcp_closed, _Socket}, State) ->
    {stop, normal, State};

handle_info(Req, State) ->
    {stop, {unexpected, Req}, State}.

%% @private
-spec handle_call({send, #sip_message{}}, _, #state{}) ->
          {reply, ok | {error, Reason :: term()}, #state{}} | {stop, {unexpected, _}, #state{}}.
handle_call({send, Message}, _From, State) ->
    Socket = State#state.socket,
    Packet = sip_message:to_binary(Message),
    Result = gen_tcp:send(Socket, Packet),
    {reply, Result, State};

handle_call(Req, _From, State) ->
    {stop, {unexpected, Req}, State}.

%% @private
-spec handle_cast(_, #state{}) -> {stop, {unexpected, _}, #state{}}.
handle_cast(Req, State) ->
    {stop, {unexpected, Req}, State}.

%% @private
-spec terminate(term(), #state{}) -> ok.
terminate(_Reason, _State) ->
    ok.

%% @private
-spec code_change(term(), #state{}, term()) -> {ok, #state{}}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
