%%%----------------------------------------------------------------
%%% @author  Ivan Dubrov <dubrov.ivan@gmail.com>
%%% @doc SIP headers parsing/generation and utility functions
%%%
%%% FIXME: need to verify that all binary generation properly unescapes/escapes characters!
%%% @end
%%% @reference See <a href="http://tools.ietf.org/html/rfc3261#section-20">RFC 3261</a> for details.
%%% @copyright 2011 Ivan Dubrov. See LICENSE file.
%%%----------------------------------------------------------------
-module(sip_headers).

%%-----------------------------------------------------------------
%% Exports
%%-----------------------------------------------------------------
-export([parse_headers/1, format_headers/1]).
-export([parse/2, format/2]).
-export([media/3, language/2, encoding/2, auth/2, info/2, via/3, cseq/2, address/3]).
-export([add_tag/3]).

%%-----------------------------------------------------------------
%% Macros
%%-----------------------------------------------------------------

%%-----------------------------------------------------------------
%% Include files
%%-----------------------------------------------------------------
-include("sip_common.hrl").
-include("sip_parse.hrl").
-include("sip.hrl").

%%-----------------------------------------------------------------
%% API functions
%%-----------------------------------------------------------------

%% @doc Parse binary into list of headers
%%
%% Convert binary containing headers into list of non-parsed headers
%% (with binary values). Binary must be `\r\n' separated headers. If
%% at least one header is present, binary must end with `\r\n'. Otherwise,
%% it must be empty binary.
%% @end
-spec parse_headers(binary()) -> [{Name :: atom() | binary(), Value :: binary() | term()}].
parse_headers(<<>>) -> [];
parse_headers(Headers) when is_binary(Headers) ->
    Pos = size(Headers) - 2,
    <<Headers2:Pos/binary, "\r\n">> = Headers,
    Lines = binary:split(Headers2, <<"\r\n">>, [global]),
    lists:reverse(lists:foldl(fun (Bin, List) -> fold_header(Bin, List) end, [], Lines)).

%% @doc Convert header name and value into the binary
%% @end
-spec format_headers([{atom() | binary(), binary() | term()}]) -> binary().
format_headers(Headers) ->
    << <<(process(fn, Name, ignore))/binary, ": ",
         (format(Name, Value))/binary, "\r\n">> ||
       {Name, Value} <- Headers>>.

%%-----------------------------------------------------------------
%% Header parsing/format functions
%%-----------------------------------------------------------------

parse(Name, Bin) -> process(p, Name, Bin).

%% @doc Format header value into the binary.
%% @end
format(Name, [Value]) -> process(f, Name, Value);
format(Name, [Top | Rest]) ->
    Joiner =
        fun (Elem, Bin) ->
                 ElemBin = process(f, Name, Elem),
                 <<Bin/binary, ?COMMA, ?SP, ElemBin/binary>>
        end,
    TopBin = process(f, Name, Top),
    lists:foldl(Joiner, TopBin, Rest);
format(Name, Value) -> process(f, Name, Value).

%% @doc Parse/format header name/value
%%
%% Parsing/formatting merged into single function for better locality of changes.
%% @end
-spec process(p | f | pn | fn, Name :: atom() | binary(), Value :: any()) -> term().

% Default header processing
process(p, _Name, Header) when not is_binary(Header) -> Header; % already parsed
process(f, _Name, Value) when is_binary(Value) -> Value; % already formatted

%% 20.1 Accept
%% http://tools.ietf.org/html/rfc3261#section-20.1
process(fn, 'accept', _Ignore) -> <<"Accept">>;
process(p, 'accept', Bin) ->
    {Media, Rest} = parse_media_range(Bin, fun parse_q_param/2),
    parse_list('accept', Media, Rest);

process(f, 'accept', Accept) when is_record(Accept, sip_hdr_mediatype) ->
    Type = sip_binary:any_to_binary(Accept#sip_hdr_mediatype.type),
    SubType = sip_binary:any_to_binary(Accept#sip_hdr_mediatype.subtype),
    append_params(<<Type/binary, ?SLASH, SubType/binary>>, Accept#sip_hdr_mediatype.params);

%% 20.2 Accept-Encoding
%% http://tools.ietf.org/html/rfc3261#section-20.2
process(fn, 'accept-encoding', _Ignore) -> <<"Accept-Encoding">>;
process(p, 'accept-encoding', Bin) ->
    {EncodingBin, Params, Rest} = parse_accept(Bin),
    Encoding = encoding(sip_binary:binary_to_existing_atom(EncodingBin), Params),
    parse_list('accept-encoding', Encoding, Rest);

process(f, 'accept-encoding', Accept) when is_record(Accept, sip_hdr_encoding) ->
    Encoding = sip_binary:any_to_binary(Accept#sip_hdr_encoding.encoding),
    append_params(Encoding, Accept#sip_hdr_encoding.params);

%% 20.3 Accept-Language
%% http://tools.ietf.org/html/rfc3261#section-20.3
process(fn, 'accept-language', _Ignore) -> <<"Accept-Language">>;
process(p, 'accept-language', Bin) ->
    {Language, Rest} = parse_language(sip_binary:trim_leading(Bin)),
    {Params, Rest2} = parse_params(Rest, fun parse_q_param/2),
    parse_list('accept-language', language(Language, Params), Rest2);

process(f, 'accept-language', Accept) when is_record(Accept, sip_hdr_language) ->
    LangBin = sip_binary:any_to_binary(Accept#sip_hdr_language.language),
    append_params(LangBin, Accept#sip_hdr_language.params);

%% 20.4 Alert-Info
%% http://tools.ietf.org/html/rfc3261#section-20.4
process(fn, 'alert-info', _Ignore) -> <<"Alert-Info">>;
process(p, 'alert-info', Bin) ->
    parse_info('alert-info', Bin, fun parse_generic_param/2);

process(f, 'alert-info', Info) when is_record(Info, sip_hdr_info) ->
    URI = sip_uri:format(Info#sip_hdr_info.uri),
    Bin = <<?LAQUOT, URI/binary, ?RAQUOT>>,
    append_params(Bin, Info#sip_hdr_info.params);

%% 20.5 Allow
%% http://tools.ietf.org/html/rfc3261#section-20.5
process(fn, 'allow', _Ignore) -> <<"Allow">>;
process(p, 'allow', Bin) ->
    {MethodBin, Rest} = sip_binary:parse_token(Bin),
    Method = sip_binary:binary_to_existing_atom(sip_binary:to_upper(MethodBin)),
    parse_list('allow', Method, Rest);

process(f, 'allow', Allow) ->
    sip_binary:any_to_binary(Allow);

%% 20.6 Authentication-Info
%% http://tools.ietf.org/html/rfc3261#section-20.6
process(fn, 'authentication-info', _Ignore) -> <<"Authentication-Info">>;
process(p, 'authentication-info', Bin) ->
    parse_auths(Bin);

process(f, 'authentication-info', {_Key, _Value} = Pair) ->
    format_auth(Pair);

%% 20.7 Authorization
%% http://tools.ietf.org/html/rfc3261#section-20.7
process(fn, 'authorization', _Ignore) -> <<"Authorization">>;
process(p, 'authorization', Bin) ->
    {SchemeBin, Bin2} = sip_binary:parse_token(Bin),
    % parse scheme, the rest is list of paris param=value
    Scheme = sip_binary:binary_to_existing_atom(SchemeBin),
    auth(Scheme, parse_auths(Bin2));

process(f, 'authorization', Auth) when is_record(Auth, sip_hdr_auth) ->
    SchemeBin = sip_binary:any_to_binary(Auth#sip_hdr_auth.scheme),
    [First | Rest] = Auth#sip_hdr_auth.params,
    FirstBin = format_auth(First),
    Fun = fun (Val, Acc) -> <<Acc/binary, ?COMMA, ?SP, (format_auth(Val))/binary>> end,
    lists:foldl(Fun, <<SchemeBin/binary, ?SP, FirstBin/binary>>, Rest);

%% 20.8 Call-ID
%% http://tools.ietf.org/html/rfc3261#section-20.8
process(pn, <<"i">>, _Ignore) -> 'call-id';
process(fn, 'call-id', _Ignore) -> <<"Call-ID">>;
process(p, 'call-id', Bin) -> Bin;

%% 20.9 Call-Info
%% http://tools.ietf.org/html/rfc3261#section-20.9
process(fn, 'call-info', _Ignore) -> <<"Call-Info">>;
process(p, 'call-info', Bin) ->
    ParamFun =
        fun(purpose, Value) -> sip_binary:binary_to_existing_atom(Value);
           (_Name, Value) -> Value
        end,
    parse_info('call-info', Bin, ParamFun);

process(f, 'call-info', Info) when is_record(Info, sip_hdr_info) ->
    URI = sip_uri:format(Info#sip_hdr_info.uri),
    Bin = <<?LAQUOT, URI/binary, ?RAQUOT>>,
    append_params(Bin, Info#sip_hdr_info.params);

%% 20.10 Contact
%% http://tools.ietf.org/html/rfc3261#section-20.10
process(pn, <<"m">>, _Ignore) -> 'contact';
process(fn, 'contact', _Ignore) -> <<"Contact">>;
process(p, 'contact', <<"*">>) -> '*';
process(p, 'contact', Bin) ->
    {Top, Rest} = parse_address(Bin, fun parse_contact_param/2),
    parse_list('contact', Top, Rest);

process(f, 'contact', '*') -> <<"*">>;
process(f, 'contact', Addr) when is_record(Addr, sip_hdr_address) ->
    format_address(Addr);

%% 20.11 Content-Disposition
%% http://tools.ietf.org/html/rfc3261#section-20.11
process(fn, 'content-disposition', _Ignore) -> <<"Content-Disposition">>;
process(p, 'content-disposition', Bin) ->
    {TypeBin, Rest} = sip_binary:parse_token(Bin),
    ParamFun = fun(handling, Value) -> sip_binary:binary_to_existing_atom(Value);
                  (_Name, Value) -> Value
               end,
    {Params, <<>>} = parse_params(Rest, ParamFun),
    Type = sip_binary:binary_to_existing_atom(TypeBin),
    #sip_hdr_disposition{type = Type, params = Params};

process(f, 'content-disposition', Disp) when is_record(Disp, sip_hdr_disposition) ->
    TypeBin = sip_binary:any_to_binary(Disp#sip_hdr_disposition.type),
    append_params(TypeBin, Disp#sip_hdr_disposition.params);

%% 20.12 Content-Encoding
%% http://tools.ietf.org/html/rfc3261#section-20.12
process(pn, <<"e">>, _Ignore) -> 'content-encoding';
process(fn, 'content-encoding', _Ignore) -> <<"Content-Encoding">>;
process(p, 'content-encoding', Bin) ->
    {MethodBin, Rest} = sip_binary:parse_token(Bin),
    Method = sip_binary:binary_to_existing_atom(sip_binary:to_lower(MethodBin)),
    parse_list('content-encoding', Method, Rest);

process(f, 'content-encoding', Allow) ->
    sip_binary:any_to_binary(Allow);

%% 20.13 Content-Language
%% http://tools.ietf.org/html/rfc3261#section-20.13
process(fn, 'content-language', _Ignore) -> <<"Content-Language">>;
process(p, 'content-language', Bin) ->
    {LangBin, Rest} = sip_binary:parse_token(Bin),
    {Language, <<>>} = parse_language(LangBin),
    parse_list('content-language', Language, Rest);

process(f, 'content-language', Lang) ->
    sip_binary:any_to_binary(Lang);

%% 20.14 Content-Length
%% http://tools.ietf.org/html/rfc3261#section-20.14
process(pn, <<"l">>, _Ignore) -> 'content-length';
process(fn, 'content-length', _Ignore) -> <<"Content-Length">>;
process(p, 'content-length', Bin) ->
    sip_binary:binary_to_integer(Bin);

process(f, 'content-length', Length) when is_integer(Length) ->
    sip_binary:integer_to_binary(Length);

%% 20.15 Content-Type
%% http://tools.ietf.org/html/rfc3261#section-20.15
process(pn, <<"c">>, _Ignore) -> 'content-type';
process(fn, 'content-type', _Ignore) -> <<"Content-Type">>;
process(p, 'content-type', Bin) ->
    {Media, <<>>} = parse_media_range(Bin, fun parse_generic_param/2),
    Media;

process(f, 'content-type', CType) when is_record(CType, sip_hdr_mediatype) ->
    Type = sip_binary:any_to_binary(CType#sip_hdr_mediatype.type),
    SubType = sip_binary:any_to_binary(CType#sip_hdr_mediatype.subtype),
    append_params(<<Type/binary, ?SLASH, SubType/binary>>, CType#sip_hdr_mediatype.params);

%% 20.16 CSeq
%% http://tools.ietf.org/html/rfc3261#section-20.16
process(fn, 'cseq', _Ignore) -> <<"CSeq">>;
process(p, 'cseq', Bin) ->
    {SeqBin, Bin2} = sip_binary:parse_token(Bin),
    {MethodBin, <<>>} = sip_binary:parse_token(Bin2),
    Sequence = sip_binary:binary_to_integer(SeqBin),
    Method = sip_binary:binary_to_existing_atom(sip_binary:to_upper(MethodBin)),
    cseq(Sequence, Method);

process(f, 'cseq', CSeq) when is_record(CSeq, sip_hdr_cseq) ->
    SequenceBin = sip_binary:integer_to_binary(CSeq#sip_hdr_cseq.sequence),
    MethodBin = sip_binary:any_to_binary(CSeq#sip_hdr_cseq.method),
    <<SequenceBin/binary, " ", MethodBin/binary>>;

%% 20.17 Date
%% http://tools.ietf.org/html/rfc3261#section-20.17
process(fn, 'date', _Ignore) -> <<"Date">>;
process(p, 'date', Bin) ->
    httpd_util:convert_request_date(binary_to_list(Bin));

process(f, 'date', Date) ->
    Local = calendar:universal_time_to_local_time(Date),
    list_to_binary(httpd_util:rfc1123_date(Local));

%% 20.18 Error-Info
%% http://tools.ietf.org/html/rfc3261#section-20.18
process(fn, 'error-info', _Ignore) -> <<"Error-Info">>;
process(p, 'error-info', Bin) ->
    parse_info('call-info', Bin, fun parse_generic_param/2);

process(f, 'error-info', Info) when is_record(Info, sip_hdr_info) ->
    URI = sip_uri:format(Info#sip_hdr_info.uri),
    Bin = <<?LAQUOT, URI/binary, ?RAQUOT>>,
    append_params(Bin, Info#sip_hdr_info.params);

%% 20.19 Expires
%% http://tools.ietf.org/html/rfc3261#section-20.19
process(fn, 'expires', _Ignore) -> <<"Expires">>;
process(p, 'expires', Bin) ->
    sip_binary:binary_to_integer(Bin);

process(f, 'expires', Length) when is_integer(Length) ->
    sip_binary:integer_to_binary(Length);

%% 20.20 From
%% http://tools.ietf.org/html/rfc3261#section-20.20
process(pn, <<"f">>, _Ignore) -> 'from';
process(fn, 'from', _Ignore) -> <<"From">>;
process(p, 'from', Bin) ->
    {Top, <<>>} = parse_address(Bin, fun parse_generic_param/2),
    Top;

process(f, 'from', Addr) when is_record(Addr, sip_hdr_address) ->
    format_address(Addr);

%% 20.21 In-Reply-To
%% http://tools.ietf.org/html/rfc3261#section-20.21
process(fn, 'in-reply-to', _Ignore) -> <<"In-Reply-To">>;
process(p, 'in-reply-to', Bin) ->
    Bin2 = sip_binary:trim_leading(Bin),
    Fun = fun (C) -> sip_binary:is_space_char(C) orelse C =:= ?COMMA end,
    {InReplyTo, Rest} = sip_binary:parse_until(Bin2, Fun),
    parse_list('in-reply-to', InReplyTo, Rest);

%% 20.22 Max-Forwards
%% http://tools.ietf.org/html/rfc3261#section-20.22
process(fn, 'max-forwards', _Ignore) -> <<"Max-Forwards">>;
process(p, 'max-forwards', Bin) ->
    sip_binary:binary_to_integer(Bin);

process(f, 'max-forwards', Hops) when is_integer(Hops) ->
    sip_binary:integer_to_binary(Hops);

%% 20.23 Min-Expires
%% http://tools.ietf.org/html/rfc3261#section-20.23
process(fn, 'min-expires', _Ignore) -> <<"Min-Expires">>;
process(p, 'min-expires', Bin) ->
    sip_binary:binary_to_integer(Bin);

process(f, 'min-expires', Length) when is_integer(Length) ->
    sip_binary:integer_to_binary(Length);


%% .....
process(pn, <<"v">>, _Ignore) -> 'via';
process(fn, 'via', _Ignore) -> <<"Via">>;
process(p, 'via', Bin) ->
    {{<<"SIP">>, Version, Transport}, Bin2} = parse_sent_protocol(Bin),
    % Parse parameters (which should start with semicolon)
    {Host, Port, Bin3} = sip_binary:parse_host_port(Bin2),
    {Params, Rest} = parse_params(Bin3, fun parse_via_param/2),

    Top = #sip_hdr_via{transport = Transport,
                       version = Version,
                       host = Host,
                       port = Port,
                       params = Params},
    parse_list('via', Top, Rest);

process(f, 'via', Via) when is_record(Via, sip_hdr_via) ->
    Version = Via#sip_hdr_via.version,
    Transport = sip_binary:to_upper(atom_to_binary(Via#sip_hdr_via.transport, latin1)),
    Bin = <<"SIP/", Version/binary, $/, Transport/binary>>,
    Host = sip_binary:addr_to_binary(Via#sip_hdr_via.host),
    Bin2 =
        case Via#sip_hdr_via.port of
            undefined -> <<Bin/binary, ?SP, Host/binary>>;
            Port -> <<Bin/binary, ?SP, Host/binary, ?HCOLON, (sip_binary:integer_to_binary(Port))/binary>>
        end,
    append_params(Bin2, Via#sip_hdr_via.params);

%% ....


%% ....
process(pn, <<"t">>, _Ignore) -> 'to';
process(fn, 'to', _Ignore) -> <<"To">>;
process(p, 'to', Bin) ->
    {Top, <<>>} = parse_address(Bin, fun parse_generic_param/2),
    Top;

process(f, 'to', Addr) when is_record(Addr, sip_hdr_address) ->
    format_address(Addr);

%% ...
process(fn, 'route', _Ignore) -> <<"Route">>;
process(p, 'route', Bin) ->
    {Top, Rest} = parse_address(Bin, fun parse_generic_param/2),
    parse_list('route', Top, Rest);

process(f, 'route', Route) when is_record(Route, sip_hdr_address) ->
    format_address(Route);

%% ...
process(fn, 'record-route', _Ignore) -> <<"Record-Route">>;
process(p, 'record-route', Bin) ->
    {Top, Rest} = parse_address(Bin, fun parse_generic_param/2),
    parse_list('record-route', Top, Rest);

process(f, 'record-route', RecordRoute) when is_record(RecordRoute, sip_hdr_address) ->
    format_address(RecordRoute);

%% ...
process(fn, 'require', _Ignore) -> <<"Require">>;
process(p, 'require', Bin) ->
    {ExtBin, Rest} = sip_binary:parse_token(Bin),
    Ext = sip_binary:binary_to_existing_atom(sip_binary:to_lower(ExtBin)),
    parse_list('require', Ext, Rest);

process(f, 'require', Ext) ->
    sip_binary:any_to_binary(Ext);

%% ...
process(fn, 'proxy-require', _Ignore) -> <<"Proxy-Require">>;
process(p, 'proxy-require', Bin) ->
    {ExtBin, Rest} = sip_binary:parse_token(Bin),
    Ext = sip_binary:binary_to_existing_atom(sip_binary:to_lower(ExtBin)),
    parse_list('proxy-require', Ext, Rest);

process(f, 'proxy-require', Ext) ->
    sip_binary:any_to_binary(Ext);

%% ...
process(pn, <<"k">>, _Ignore) -> 'supported';
process(fn, 'supported', _Ignore) -> <<"Supported">>;
process(p, 'supported', Bin) ->
    {ExtBin, Rest} = sip_binary:parse_token(Bin),
    Ext = sip_binary:binary_to_existing_atom(sip_binary:to_lower(ExtBin)),
    parse_list('supported', Ext, Rest);

process(f, 'supported', Ext) ->
    sip_binary:any_to_binary(Ext);

%% ...
process(fn, 'unsupported', _Ignore) -> <<"Unsupported">>;
process(p, 'unsupported', Bin) ->
    {ExtBin, Rest} = sip_binary:parse_token(Bin),
    Ext = sip_binary:binary_to_existing_atom(sip_binary:to_lower(ExtBin)),
    parse_list('require', Ext, Rest);

process(f, 'unsupported', Ext) ->
    sip_binary:any_to_binary(Ext);

% Default header processing
process(p, _Name, Header) -> Header; % cannot parse, leave as is
process(f, _Name, Value) -> sip_binary:any_to_binary(Value);
process(pn, Name, _Ignore) when is_binary(Name) -> sip_binary:binary_to_existing_atom(Name);
process(fn, Name, _Ignore) when is_binary(Name) -> Name;
process(fn, Name, _Ignore) when is_atom(Name) -> atom_to_binary(Name, utf8).


%% Internal helpers to parse header parts

%% sent-protocol     =  protocol-name SLASH protocol-version
%%                      SLASH transport
%% protocol-name     =  "SIP" / token
%% protocol-version  =  token
%% transport         =  "UDP" / "TCP" / "TLS" / "SCTP"
%%                      / other-transport
%% other-transport   =  token
parse_sent_protocol(Bin) ->
    {Protocol, <<$/, Bin2/binary>>} = sip_binary:parse_token(Bin),
    {Version, <<$/, Bin3/binary>>} = sip_binary:parse_token(Bin2),
    {Transport, Bin4} = sip_binary:parse_token(Bin3),
    Transport2 = sip_binary:binary_to_existing_atom(sip_binary:to_lower(Transport)),
    {{Protocol, Version, Transport2}, Bin4}.

%% Parse parameters lists
%% *( SEMI param )
%% param  =  token [ EQUAL value ]
%% value  =  token / host / quoted-string
parse_params(Bin, ParseFun) ->
    parse_params_loop(sip_binary:trim_leading(Bin), ParseFun, []).

parse_params_loop(<<?SEMI, Bin/binary>>, ParseFun, List) ->
    {NameBin, MaybeValue} = sip_binary:parse_token(Bin),
    Name = sip_binary:binary_to_existing_atom(NameBin),
    {Value, Rest} =
        case MaybeValue of
            % Parameter with value
            <<?EQUAL, Bin2/binary>> ->
                parse_token_or_quoted(Bin2);
            % Parameter without a value ('true' value)
            Next ->
                {true, Next}
        end,
    ParsedValue = ParseFun(Name, Value),
    Property = proplists:property(Name, ParsedValue),
    parse_params_loop(Rest, ParseFun, [Property | List]);
parse_params_loop(Bin, _ParseFun, List) ->
    {lists:reverse(List), sip_binary:trim_leading(Bin)}.

parse_token_or_quoted(Bin) ->
    case sip_binary:trim_leading(Bin) of
        <<?DQUOTE, _Rest/binary>> -> sip_binary:parse_quoted_string(Bin);
        _Token -> sip_binary:parse_token(Bin)
    end.

%% Parse address-like headers (`Contact:', `To:', `From:')
parse_address(Bin, ParamFun) ->
    {Display, URI, Bin2} = parse_address_uri(sip_binary:trim_leading(Bin)),
    {Params, Bin3} = parse_params(Bin2, ParamFun),
    Value = address(sip_binary:trim(Display), URI, Params),
    {Value, Bin3}.

parse_address_uri(<<?DQUOTE, _/binary>> = Bin) ->
    % name-addr with quoted-string display-name
    {Display, <<?LAQUOT, Rest/binary>>} = sip_binary:parse_quoted_string(Bin),
    {URI, <<?RAQUOT, Params/binary>>} = sip_binary:parse_until(Rest, ?RAQUOT),
    {Display, URI, Params};
parse_address_uri(<<?LAQUOT, Rest/binary>>) ->
    % name-addr without display-name
    {URI, <<?RAQUOT, Params/binary>>} = sip_binary:parse_until(Rest, ?RAQUOT),
    {<<>>, URI, Params};
parse_address_uri(Bin) ->
    % either addr-spec or name-addr with token-based display-name
    case sip_binary:parse_until(Bin, ?LAQUOT) of
        {_Any, <<>>} ->
            % addr-spec
            % Section 20
            % If the URI is not enclosed in angle brackets, any semicolon-delimited
            % parameters are header-parameters, not URI parameters.
            % so, parse until comma (next header value), space character or semicolon
            Fun = fun (C) -> sip_binary:is_space_char(C) orelse C =:= ?SEMI orelse C =:= ?COMMA end,

            {URI, Params} = sip_binary:parse_until(Bin, Fun),
            {<<>>, URI, Params};

        {Display, <<?LAQUOT, Rest/binary>>} ->
            % name-addr with token-based display-name
            {URI, <<?RAQUOT, Params/binary>>} = sip_binary:parse_until(Rest, ?RAQUOT),
            {Display, URI, Params}
    end.

format_address(Addr) ->
    URIBin = sip_uri:format(Addr#sip_hdr_address.uri),
    Bin = case Addr#sip_hdr_address.display_name of
              <<>> -> <<?LAQUOT, URIBin/binary, ?RAQUOT>>;
              DisplayName ->
                  Quoted = sip_binary:quote_string(DisplayName),
                  <<Quoted/binary, " ", ?LAQUOT, URIBin/binary, ?RAQUOT>>
          end,
    append_params(Bin, Addr#sip_hdr_address.params).


%% Parse accept-range or media-type grammar
parse_media_range(Bin, ParamFun) ->
    {Type2, SubType2, ParamsBin2} =
        case sip_binary:trim_leading(Bin) of
            <<"*/*", ParamsBin/binary>> ->
                {'*', '*', ParamsBin};
        _ ->
            {TypeBin, <<?SLASH, Bin2/binary>>} = sip_binary:parse_token(Bin),
            Type = sip_binary:binary_to_existing_atom(TypeBin),
            case sip_binary:trim_leading(Bin2) of
                <<"*", ParamsBin/binary>> -> {Type, '*', ParamsBin};
                Bin3 ->
                    {SubTypeBin, ParamsBin} = sip_binary:parse_token(Bin3),
                    SubType = sip_binary:binary_to_existing_atom(SubTypeBin),
                    {Type, SubType, ParamsBin}
            end
    end,
    {Params, Rest} = parse_params(ParamsBin2, ParamFun),
    {media(Type2, SubType2, Params), Rest}.


%% Parse `Alert-Info' or `Call-Info' like headers
parse_info(Name, Bin, ParamFun) ->
    <<?LAQUOT, Bin2/binary>> = sip_binary:trim_leading(Bin),
    {URI, <<?RAQUOT, Bin3/binary>>} = sip_binary:parse_until(Bin2, ?RAQUOT),
    {Params, Rest} = parse_params(Bin3, ParamFun),
    Info = info(URI, Params),
    parse_list(Name, Info, Rest).

%% Parse Accept-Encoding grammar
parse_accept(Bin) ->
    {TokenBin, ParamsBin} =
        case sip_binary:trim_leading(Bin) of
            <<"*", P/binary>> -> {'*', P};
            Bin2 -> sip_binary:parse_token(Bin2)
    end,
    {Params, Rest} = parse_params(ParamsBin, fun parse_q_param/2),
    {TokenBin, Params, Rest}.

%% @doc Append parameters to the binary
%% @end
append_params(Bin, Params) ->
    lists:foldl(fun format_param/2, Bin, Params).

%% @doc
%% Format semi-colon separated list of parameters
%% Each parameter is either binary (parameter name) or
%% tuple of two binaries (parameter name and value).
%% @end
format_param({Name, Value}, Bin) ->
    Name2 = sip_binary:any_to_binary(Name),

    % If contains non-token characters, write as quoted string
    Value2 = case need_quoting(Value) of
                 true -> sip_binary:quote_string(Value);
                 false -> Value
             end,
    Value3 = sip_binary:any_to_binary(Value2),
    <<Bin/binary, ?SEMI, Name2/binary, ?EQUAL, Value3/binary>>;
format_param(Name, Bin) ->
    Name2 = sip_binary:any_to_binary(Name),
    <<Bin/binary, ?SEMI, Name2/binary>>.

need_quoting(Value) when not is_binary(Value) ->
    % no need to escape non-binary values
    % (it could be number, IP address, atom)
    false;
need_quoting(<<>>) ->
    false;
need_quoting(<<C, Rest/binary>>)  ->
    (not sip_binary:is_token_char(C)) orelse need_quoting(Rest).

%%-----------------------------------------------------------------
%% Header-specific helpers
%%-----------------------------------------------------------------

%% @doc
%% Construct Via header value.
%% @end
-spec via(atom(), {string() | inet:ip_address(), integer() | 'undefined'} | string(), [any()]) -> #sip_hdr_via{}.
via(Transport, {Host, Port}, Params) when
  is_atom(Transport), is_list(Params), (is_list(Host) orelse is_tuple(Host)) ->
    #sip_hdr_via{transport = Transport, host = Host, port = Port, params = Params};
via(Transport, Host, Params) when is_list(Host); is_tuple(Host) ->
    via(Transport, {Host, 5060}, Params).

%% @doc Construct media type value.
%% @end
-spec media(atom() | binary(), atom() | binary(), [any()]) -> #sip_hdr_mediatype{}.
media(Type, SubType, Params) when is_list(Params) ->
    #sip_hdr_mediatype{type = Type, subtype = SubType, params = Params}.

%% @doc Construct encoding type value.
%% @end
-spec encoding(atom() | binary(), [any()]) -> #sip_hdr_encoding{}.
encoding(Encoding, Params) when is_list(Params) ->
    #sip_hdr_encoding{encoding = Encoding, params = Params}.

%% @doc Construct language type value.
%% @end
-spec language(atom() | binary(), [any()]) -> #sip_hdr_language{}.
language(Language, Params) when is_list(Params) ->
    #sip_hdr_language{language = Language, params = Params}.

%% @doc Construct `Alert-Info', `Call-Info' headers value
%% @end
-spec info(#sip_uri{} | binary(), [any()]) -> #sip_hdr_info{}.
info(URI, Params) ->
    #sip_hdr_info{uri = URI, params = Params}.

%% @doc Construct `Authorization:' header value
%% @end
-spec auth(binary() | atom(), [any()]) -> #sip_hdr_auth{}.
auth(Scheme, Params) ->
    #sip_hdr_auth{scheme = Scheme, params = Params}.

%% @doc
%% Construct CSeq header value.
%% @end
-spec cseq(integer(), atom() | binary()) -> #sip_hdr_cseq{}.
cseq(Sequence, Method) when
  is_integer(Sequence),
  (is_atom(Method) orelse is_binary(Method)) ->
    #sip_hdr_cseq{method = Method, sequence = Sequence}.


%% @doc Construct address (value of From/To headers).
%%
%% <em>Note: parses URI if it is given in binary form</em>
%% @end
-spec address(binary(), #sip_uri{} | #tel_uri{} | binary(), list()) -> #sip_hdr_address{}.
address(DisplayName, URI, Params) when is_binary(DisplayName), is_list(Params), is_binary(URI) ->
    #sip_hdr_address{display_name = DisplayName, uri = sip_uri:parse(URI), params = Params};
address(DisplayName, URI, Params) when is_binary(DisplayName), is_list(Params) ->
    #sip_hdr_address{display_name = DisplayName, uri = URI, params = Params}.

%% @doc Add tag to the `From:' or `To:' header.
%% @end
-spec add_tag(atom(), #sip_hdr_address{}, binary()) -> #sip_hdr_address{}.
add_tag(Name, Value, Tag) when Name =:= 'to'; Name =:= 'from' ->
    Value2 = parse(Name, Value),
    Params = lists:keystore('tag', 1, Value2#sip_hdr_address.params, {'tag', Tag}),
    Value2#sip_hdr_address{params = Params}.

%%-----------------------------------------------------------------
%% Internal functions
%%-----------------------------------------------------------------

%% Parsing/formatting authentication/authorization parameters
parse_auths(Bin) ->
    {NameBin, <<?EQUAL, ValueBin/binary>>} = sip_binary:parse_token(Bin),
    Name = sip_binary:binary_to_existing_atom(NameBin),
    {Value, Rest} =
        case Name of
            _ when Name =:= nextnonce; Name =:= nonce; Name =:= cnonce;
                   Name =:= username; Name =:= realm; Name =:= uri;
                   Name =:= opaque ->
                sip_binary:parse_quoted_string(ValueBin);
            _ when Name =:= qop; Name =:= algorithm ->
                {Val, R} = sip_binary:parse_token(ValueBin),
                {sip_binary:binary_to_existing_atom(Val), R};
            _ when Name =:= rspauth; Name =:= response ->
                {Digest, R} = sip_binary:parse_quoted_string(ValueBin),
                {sip_binary:hexstr_to_binary(Digest), R};
            nc ->
                {NC, R} = sip_binary:parse_while(ValueBin, fun sip_binary:is_alphanum_char/1),
                {list_to_integer(binary_to_list(NC), 16), sip_binary:trim_leading(R)};
            % arbitrary auth-param
            _Other ->
                parse_token_or_quoted(ValueBin)
        end,
    Info = {Name, Value},
    case Rest of
        <<>> -> [Info];
        <<?COMMA, Rest2/binary>> ->
            [Info | parse_auths(Rest2)]
    end.

format_auth({Name, Value}) ->
    NameBin = sip_binary:any_to_binary(Name),
    ValBin = format_auth(Name, Value),
    <<NameBin/binary, ?EQUAL, ValBin/binary>>.

format_auth(Name, Value) when
  Name =:= nextnonce; Name =:= nonce; Name =:= cnonce;
  Name =:= username; Name =:= realm; Name =:= uri;
  Name =:= opaque ->
    sip_binary:quote_string(Value);
format_auth(Name, Qop)
  when Name =:= qop; Name =:= algorithm ->
    sip_binary:any_to_binary(Qop);
format_auth(Name, Bin) when Name =:= rspauth; Name =:= response ->
    HexStr = sip_binary:binary_to_hexstr(Bin),
    sip_binary:quote_string(HexStr);
format_auth(nc, NonceCount) ->
    [NCBin] = io_lib:format("~8.16.0b", [NonceCount]),
    list_to_binary(NCBin);
format_auth(_Name, Value) when is_binary(Value) ->
    % arbitrary auth-param
    case need_quoting(Value) of
        true -> sip_binary:quote_string(Value);
        false -> Value
    end.

%% @doc Multi-headers parse helper
%% @end
parse_list(_Name, Top, <<>>) -> [Top];
parse_list(Name, Top, <<?COMMA, Rest/binary>>) -> [Top | parse(Name, Rest)].

%% @doc Parse language range
%% language-range   =  ( ( 1*8ALPHA *( "-" 1*8ALPHA ) ) / "*" )
%% @end
parse_language(<<$*, Rest/binary>>) -> {'*', Rest};
parse_language(Bin) ->
    IsLangChar = fun(C) -> sip_binary:is_alpha_char(C) orelse C =:= $- end,
    {LangBin, Rest} = sip_binary:parse_while(Bin, IsLangChar),
    {sip_binary:binary_to_existing_atom(LangBin), Rest}.


% RFC 3261, 7.3.1
% The line break and the whitespace at the beginning of the next
% line are treated as a single SP character. This function appends
% such lines to the last header.
fold_header(<<C/utf8, _/binary>> = Line, [{Name, Value} | Tail]) when
  C =:= ?SP; C =:= ?HTAB ->
    Line2 = sip_binary:trim_leading(Line),
    Value2 = sip_binary:trim_trailing(Value),
    [{Name, <<Value2/binary, ?SP, Line2/binary>>} | Tail];
fold_header(HeaderLine, List) ->
    [Name, Value] = binary:split(HeaderLine, <<?HCOLON>>),
    Name2 = sip_binary:to_lower(sip_binary:trim_trailing(Name)),
    Name3 = process(pn, Name2, ignored),
    [{Name3, sip_binary:trim_leading(Value)} | List].

%% Parse standard Via: parameters
parse_via_param('ttl', TTL) -> sip_binary:binary_to_integer(TTL);
parse_via_param('maddr', MAddr) ->
    case sip_binary:parse_ip_address(MAddr) of
        {ok, Addr} -> Addr;
        {error, einval} -> binary_to_list(MAddr)
    end;
parse_via_param('received', Received) ->
    {ok, Addr} = sip_binary:parse_ip_address(Received),
    Addr;
parse_via_param(_Name, Value) -> Value.

%% Parse q parameter (used mostly in accept headers)
parse_q_param(q, Value) -> sip_binary:binary_to_float(Value);
parse_q_param(_Name, Value) -> Value.

%% Parse contact header parameters
parse_contact_param(q, Value) -> sip_binary:binary_to_float(Value);
parse_contact_param(expires, Value) -> sip_binary:binary_to_integer(Value);
parse_contact_param(_Name, Value) -> Value.

%% Parse generic parameters
parse_generic_param(_Name, Value) -> Value.


%%-----------------------------------------------------------------
%% Tests
%%-----------------------------------------------------------------
-ifndef(NO_TEST).

-spec parse_test_() -> list().
parse_test_() ->
    [
     % parsing
     ?_assertEqual([], parse_headers(<<>>)),

     % short names support
     ?_assertEqual([{'content-length', <<"5">>}, {'via', <<"SIP/2.0/UDP localhost">>},
                    {'from', <<"sip:alice@localhost">>}, {'to', <<"sip:bob@localhost">>},
                    {'call-id', <<"callid">>}, {'contact', <<"Alice <sip:example.com>">>},
                    {'supported', <<"100rel">>}, {'content-encoding', <<"gzip">>},
                    {'content-type', <<"application/sdp">>}],
                   parse_headers(<<"l: 5\r\nv: SIP/2.0/UDP localhost\r\n",
                                   "f: sip:alice@localhost\r\nt: sip:bob@localhost\r\n",
                                   "i: callid\r\nm: Alice <sip:example.com>\r\n",
                                   "k: 100rel\r\ne: gzip\r\n",
                                   "c: application/sdp\r\n">>)),
     % multi-line headers
     ?_assertEqual([{'subject', <<"I know you're there, pick up the phone and talk to me!">>}],
                   parse_headers(<<"Subject: I know you're there,\r\n               pick up the phone   \r\n               and talk to me!\r\n">>)),
     ?_assertEqual([{'subject', <<"I know you're there, pick up the phone and talk to me!">>}],
                   parse_headers(<<"Subject: I know you're there,\r\n\tpick up the phone    \r\n               and talk to me!\r\n">>)),

     % formatting, check that header names have proper case
     ?_assertEqual(<<"Accept: */*\r\nAccept-Encoding: identity\r\n",
                     "Accept-Language: en\r\nAlert-Info: <http://www.example.com/sounds/moo.wav>\r\n",
                     "Allow: INVITE\r\nAuthentication-Info: nextnonce=\"47364c23432d2e131a5fb210812c\"\r\n",
                     "Authorization: Digest username=\"Alice\"\r\nCall-ID: callid\r\n",
                     "Call-Info: <http://www.example.com/alice/photo.jpg>\r\nContact: *\r\n",
                     "Content-Disposition: session\r\nContent-Encoding: gzip\r\n",
                     "Content-Language: en\r\nContent-Length: 5\r\n",
                     "Content-Type: application/sdp\r\nCSeq: 123 INVITE\r\n",
                     "Date: Sat, 13 Nov 2010 23:29:00 GMT\r\nError-Info: <sip:not-in-service-recording@atlanta.com>\r\n",
                     "Expires: 213\r\nFrom: sip:alice@localhost\r\n",
                     "In-Reply-To: 70710@saturn.bell-tel.com, 17320@saturn.bell-tel.com\r\nMax-Forwards: 70\r\n",
                     "Min-Expires: 213\r\n",

                     "Content-Length: 5\r\nVia: SIP/2.0/UDP localhost\r\n",
                     "To: sip:bob@localhost\r\n"
                     "x-custom-atom: 25\r\nAllow: INVITE, ACK, CANCEL, OPTIONS, BYE\r\n",
                     "Supported: 100rel\r\nUnsupported: bar, baz\r\nRequire: foo\r\nProxy-Require: some\r\n",
                     "X-Custom: value\r\n">>,
                   format_headers([{'accept', <<"*/*">>}, {'accept-encoding', <<"identity">>},
                                   {'accept-language', <<"en">>}, {'alert-info', <<"<http://www.example.com/sounds/moo.wav>">>},
                                   {'allow', <<"INVITE">>}, {'authentication-info', <<"nextnonce=\"47364c23432d2e131a5fb210812c\"">>},
                                   {'authorization', <<"Digest username=\"Alice\"">>}, {'call-id', <<"callid">>},
                                   {'call-info', <<"<http://www.example.com/alice/photo.jpg>">>}, {'contact', <<"*">>},
                                   {'content-disposition', <<"session">>}, {'content-encoding', gzip},
                                   {'content-language', <<"en">>}, {'content-length', <<"5">>},
                                   {'content-type', <<"application/sdp">>}, {'cseq', <<"123 INVITE">>},
                                   {'date', <<"Sat, 13 Nov 2010 23:29:00 GMT">>}, {'error-info', <<"<sip:not-in-service-recording@atlanta.com>">>},
                                   {'expires', <<"213">>}, {'from', <<"sip:alice@localhost">>},
                                   {'in-reply-to', <<"70710@saturn.bell-tel.com, 17320@saturn.bell-tel.com">>}, {'max-forwards', 70},
                                   {'min-expires', <<"213">>},


                                   {'content-length', <<"5">>}, {'via', <<"SIP/2.0/UDP localhost">>},
                                   {'to', <<"sip:bob@localhost">>},
                                   {'x-custom-atom', 25},
                                   {'allow', <<"INVITE, ACK, CANCEL, OPTIONS, BYE">>},
                                   {'supported', <<"100rel">>}, {'unsupported', <<"bar, baz">>},
                                   {'require', <<"foo">>}, {'proxy-require', <<"some">>},
                                   {<<"X-Custom">>, <<"value">>}])),

     % Already parsed
     ?_assertEqual({parsed, value}, parse('x-custom2', {parsed, value})),

     % Custom header
     ?_assertEqual(<<"custom">>, parse('x-custom2', <<"custom">>)),
     ?_assertEqual(<<"25">>, format('x-custom2', 25)),

     % Accept
     ?_assertEqual([media('application', 'sdp', [{level, <<"1">>}]),
                    media('application', '*', [{q, 0.5}]),
                    media('*', '*', [{q, 0.3}])],
                   parse('accept', <<"application/sdp;level=1, application/*;q=0.5, */*;q=0.3">>)),
     ?_assertEqual(<<"application/sdp;level=1, application/*;q=0.5, */*;q=0.3">>,
                   format('accept', [media('application', 'sdp', [{level, <<"1">>}]),
                                     media('application', '*', [{q, 0.5}]),
                                     media('*', '*', [{q, 0.3}])])),

     % Accept-Encoding
     ?_assertEqual([encoding('gzip', []),
                    encoding('identity', [{q, 0.3}]),
                    encoding('*', [{q, 0.2}])],
                   parse('accept-encoding', <<"gzip, identity;q=0.3, *;q=0.2">>)),
     ?_assertEqual(<<"gzip, identity;q=0.3, *;q=0.2">>,
                   format('accept-encoding',
                          [encoding('gzip', []),
                           encoding('identity', [{q, 0.3}]),
                           encoding('*', [{q, 0.2}])])),

     % Accept-Language
     ?_assertEqual([language('da', []),
                    language('en-gb', [{q, 0.8}]),
                    language('en', [{q, 0.7}]),
                    language('*', [{q, 0.6}])],
                   parse('accept-language', <<"da, en-gb;q=0.8, en;q=0.7, *;q=0.6">>)),
     ?_assertEqual(<<"da, en-gb;q=0.8, en;q=0.7, *;q=0.6">>,
                   format('accept-language',
                          [language('da', []),
                           language('en-gb', [{q, 0.8}]),
                           language('en', [{q, 0.7}]),
                           language('*', [{q, 0.6}])])),

     % Alert-Info
     ?_assertEqual([info(<<"http://www.example.com/sounds/moo.wav">>, []),
                    info(<<"http://www.example.com/sounds/boo.wav">>, [{foo, <<"value">>}])],
                   parse('alert-info', <<"<http://www.example.com/sounds/moo.wav>, <http://www.example.com/sounds/boo.wav>;foo=value">>)),
     ?_assertEqual(<<"<http://www.example.com/sounds/moo.wav>, <http://www.example.com/sounds/boo.wav>;foo=value">>,
                   format('alert-info',
                          [info(<<"http://www.example.com/sounds/moo.wav">>, []),
                           info(<<"http://www.example.com/sounds/boo.wav">>, [{foo, <<"value">>}])])),

     % Allow
     ?_assertEqual(['INVITE', 'ACK', 'CANCEL', 'OPTIONS', 'BYE'],
                   parse('allow', <<"INVITE, ACK, CANCEL, OPTIONS, BYE">>)),
     ?_assertEqual(<<"INVITE, ACK, CANCEL, OPTIONS, BYE">>,
                   format('allow', ['INVITE', 'ACK', 'CANCEL', 'OPTIONS', 'BYE'])),

     % Authentication-Info
     ?_assertEqual([{nextnonce, <<"47364c23432">>},
                    {qop, auth},
                    {rspauth, <<95, 17, 58, 84, 50>>},
                    {cnonce, <<"42a2187831a9e">>},
                    {nc, 25}],
                   parse('authentication-info', <<"nextnonce=\"47364c23432\", qop=auth, rspauth=\"5f113a5432\", cnonce=\"42a2187831a9e\", nc=00000019">>)),
     ?_assertEqual(<<"nextnonce=\"47364c23432\", qop=auth, rspauth=\"5f113a5432\", cnonce=\"42a2187831a9e\", nc=00000019">>,
                   format('authentication-info',
                          [{nextnonce, <<"47364c23432">>},
                           {qop, auth},
                           {rspauth, <<95, 17, 58, 84, 50>>},
                           {cnonce, <<"42a2187831a9e">>},
                           {nc, 25}])),

     % Authorization
     ?_assertEqual(auth('Digest',
                        [{username, <<"Alice">>}, {realm, <<"atlanta.com">>},
                         {nonce, <<"84a4cc6f3082121f32b42a2187831a9e">>}, {uri, <<"sip:alice@atlanta.com">>},
                         {response, <<117,135,36,82,52,179,67,76,195,65,34,19,229,241,19,165>>}, {algorithm, 'MD5'},
                         {cnonce, <<"0a4f113b">>}, {opaque, <<"5ccc069c403ebaf9f0171e9517f40e41">>},
                         {qop, auth}, {nc, 1}, {param, <<"value">>}, {param2, <<"va lue">>}]),
                   parse('authorization',
                         <<"Digest username=\"Alice\", realm=\"atlanta.com\", ",
                           "nonce=\"84a4cc6f3082121f32b42a2187831a9e\", uri=\"sip:alice@atlanta.com\", ",
                           "response=\"7587245234b3434cc3412213e5f113a5\", algorithm=MD5, ",
                           "cnonce=\"0a4f113b\", opaque=\"5ccc069c403ebaf9f0171e9517f40e41\", ",
                           "qop=auth, nc=00000001, param=\"value\", param2=\"va lue\"">>)),
     ?_assertEqual(<<"Digest username=\"Alice\", realm=\"atlanta.com\", ",
                     "nonce=\"84a4cc6f3082121f32b42a2187831a9e\", uri=\"sip:alice@atlanta.com\", ",
                     "response=\"7587245234b3434cc3412213e5f113a5\", algorithm=MD5, ",
                     "cnonce=\"0a4f113b\", opaque=\"5ccc069c403ebaf9f0171e9517f40e41\", ",
                     "qop=auth, nc=00000001, param=value, param2=\"va lue\"">>,
                   format('authorization',
                          auth('Digest',
                               [{username, <<"Alice">>}, {realm, <<"atlanta.com">>},
                                {nonce, <<"84a4cc6f3082121f32b42a2187831a9e">>}, {uri, <<"sip:alice@atlanta.com">>},
                                {response, <<117,135,36,82,52,179,67,76,195,65,34,19,229,241,19,165>>}, {algorithm, 'MD5'},
                                {cnonce, <<"0a4f113b">>}, {opaque, <<"5ccc069c403ebaf9f0171e9517f40e41">>},
                                {qop, auth}, {nc, 1}, {param, <<"value">>}, {param2, <<"va lue">>}]))),


     % Call-Id
     ?_assertEqual(<<"somecallid">>, parse('call-id', <<"somecallid">>)),
     ?_assertEqual(<<"somecallid">>, format('call-id', <<"somecallid">>)),

     % Call-Info
     ?_assertEqual([info(<<"http://wwww.example.com/alice/photo.jpg">>, [{purpose, icon}]),
                    info(<<"http://www.example.com/alice/">>, [{purpose, info}, {param, <<"value">>}])],
                   parse('call-info', <<"<http://wwww.example.com/alice/photo.jpg> ;purpose=icon, <http://www.example.com/alice/> ;purpose=info;param=\"value\"">>)),
     ?_assertEqual(<<"<http://wwww.example.com/alice/photo.jpg>;purpose=icon, <http://www.example.com/alice/>;purpose=info;param=value">>,
                   format('call-info',
                          [info(<<"http://wwww.example.com/alice/photo.jpg">>, [{purpose, icon}]),
                           info(<<"http://www.example.com/alice/">>, [{purpose, info}, {param, <<"value">>}])])),

     % Contact
     ?_assertEqual([address(<<"Bob">>, <<"sip:bob@biloxi.com">>, [{q, 0.1}])],
                   parse('contact', <<"Bob <sip:bob@biloxi.com>;q=0.1">>)),
     ?_assertEqual([address(<<"Bob">>, <<"sip:bob@biloxi.com">>, [{q, 0.1}]),
                    address(<<"Alice">>, <<"sip:alice@atlanta.com">>, [{q, 0.2}])],
                   parse('contact', <<"Bob <sip:bob@biloxi.com>;q=0.1,\"Alice\" <sip:alice@atlanta.com>;q=0.2">>)),
     ?_assertEqual([address(<<"Bob">>, <<"sip:bob@biloxi.com">>, [{q, 0.1}]),
                    address(<<"Alice">>, <<"sip:alice@atlanta.com">>, [{q, 0.2}]),
                    address(<<>>, <<"sip:anonymous@example.com">>, [{param, <<"va lue">>}])],
                   parse('contact', <<"Bob <sip:bob@biloxi.com>;q=0.1, \"Alice\" <sip:alice@atlanta.com>;q=0.2, <sip:anonymous@example.com>;param=\"va lue\"">>)),
     ?_assertEqual('*', parse('contact', <<"*">>)),
     ?_assertEqual([address(<<>>, <<"sip:bob@biloxi.com">>, []),
                    address(<<>>, <<"sip:alice@atlanta.com">>, [])],
                   parse('contact', <<"sip:bob@biloxi.com, sip:alice@atlanta.com">>)),
     ?_assertEqual([address(<<"Mr. Watson">>, <<"sip:watson@worcester.bell-telephone.com">>, [{q, 0.7}, {expires, 3600}]),
                    address(<<"Mr. Watson">>, <<"mailto:watson@bell-telephone.com">>, [{q, 0.1}])],
                   parse('contact', <<"\"Mr. Watson\" <sip:watson@worcester.bell-telephone.com>;q=0.7; expires=3600, ",
                                      "\"Mr. Watson\" <mailto:watson@bell-telephone.com> ;q=0.1">>)),

     ?_assertEqual(<<"\"Bob\" <sip:bob@biloxi.com>;q=0.1">>,
                   format('contact', address(<<"Bob">>, <<"sip:bob@biloxi.com">>, [{q, 0.1}]))),
     ?_assertEqual(<<"\"Bob\" <sip:bob@biloxi.com>;q=0.1, \"Alice\" <sip:alice@atlanta.com>;q=0.2">>,
                   format('contact', [address(<<"Bob">>, <<"sip:bob@biloxi.com">>, [{q, 0.1}]),
                                      address(<<"Alice">>, <<"sip:alice@atlanta.com">>, [{q, 0.2}])])),
     ?_assertEqual(<<"\"Bob\" <sip:bob@biloxi.com>;q=0.1, \"Alice\" <sip:alice@atlanta.com>;q=0.2, <sip:anonymous@example.com>;param=\"va lue\"">>,
                   format('contact', [address(<<"Bob">>, <<"sip:bob@biloxi.com">>, [{q, 0.1}]),
                                      address(<<"Alice">>, <<"sip:alice@atlanta.com">>, [{q, 0.2}]),
                                      address(<<>>, <<"sip:anonymous@example.com">>, [{param, <<"va lue">>}])])),
     ?_assertEqual(<<"*">>, format('contact', '*')),
     ?_assertEqual(<<"<sip:bob@biloxi.com>, <sip:alice@atlanta.com>">>,
                   format('contact', [address(<<>>, <<"sip:bob@biloxi.com">>, []),
                                      address(<<>>, <<"sip:alice@atlanta.com">>, [])])),
     ?_assertEqual(<<"\"Mr. Watson\" <sip:watson@worcester.bell-telephone.com>;q=0.7;expires=3600, ",
                     "\"Mr. Watson\" <mailto:watson@bell-telephone.com>;q=0.1">>,
                   format('contact', [address(<<"Mr. Watson">>, <<"sip:watson@worcester.bell-telephone.com">>, [{q, 0.7}, {expires, 3600}]),
                                      address(<<"Mr. Watson">>, <<"mailto:watson@bell-telephone.com">>, [{q, 0.1}])])),

     % Content-Disposition
     ?_assertEqual(#sip_hdr_disposition{type = 'icon', params = [{handling, optional}, {param, <<"value">>}]},
                   parse('content-disposition', <<"icon;handling=optional;param=value">>)),
     ?_assertEqual(<<"icon;handling=optional;param=value">>,
                   format('content-disposition', #sip_hdr_disposition{type = 'icon', params = [{handling, optional}, {param, value}]})),


     % Content-Encoding
     ?_assertEqual([gzip, tar], parse('content-encoding', <<"gzip, tar">>)),
     ?_assertEqual(<<"gzip, tar">>, format('content-encoding', [gzip, tar])),

     % Content-Language
     ?_assertEqual([en, 'en-us-some'],
                   parse('content-language', <<"en, en-us-some">>)),
     ?_assertEqual(<<"en, en-us-some">>,
                   format('content-language', [en, 'en-us-some'])),

     % Content-Length
     ?_assertEqual(32543523, parse('content-length', <<"32543523">>)),
     ?_assertEqual(<<"98083">>, format('content-length', 98083)),

     % Content-Type
     ?_assertEqual(media('application', 'sdp', [{param, <<"value">>}]),
                   parse('content-type', <<"application/sdp;param=value">>)),
     ?_assertEqual(<<"application/sdp;param=value">>,
                   format('content-type', media('application', 'sdp', [{param, <<"value">>}]))),

     % CSeq
     ?_assertEqual(cseq(1231, 'ACK'), parse('cseq', <<"1231 ACK">>)),
     ?_assertEqual(<<"123453 INVITE">>, format('cseq', cseq(123453, 'INVITE'))),

     % Date
     ?_assertEqual({{2010, 11, 13}, {23, 29, 00}},
                    parse('date', <<"Sat, 13 Nov 2010 23:29:00 GMT">>)),
     ?_assertEqual(<<"Sat, 13 Nov 2010 23:29:00 GMT">>,
                    format('date', {{2010, 11, 13}, {23, 29, 00}})),

     % Error-Info
     ?_assertEqual([info(<<"sip:not-in-service-recording@atlanta.com">>, [{param, <<"value">>}])],
                   parse('error-info', <<"<sip:not-in-service-recording@atlanta.com>;param=\"value\"">>)),
     ?_assertEqual(<<"<sip:not-in-service-recording@atlanta.com>;param=value">>,
                   format('error-info', [info(<<"sip:not-in-service-recording@atlanta.com">>, [{param, <<"value">>}])])),

     % Expires
     ?_assertEqual(213, parse('expires', <<"213">>)),
     ?_assertEqual(<<"213">>, format('expires', 213)),

     % From
     ?_assertEqual(address(<<"Bob  Zert">>, <<"sip:bob@biloxi.com">>, [{'tag', <<"1928301774">>}]),
                   parse('from', <<"Bob  Zert <sip:bob@biloxi.com>;tag=1928301774">>)),
     ?_assertEqual(address(<<>>, <<"sip:bob@biloxi.com">>, [{'tag', <<"1928301774">>}]),
                   parse('from', <<"sip:bob@biloxi.com ;tag=1928301774">>)),
     ?_assertEqual(address(<<>>, <<"sip:bob@biloxi.com">>, [{'tag', <<"1928301774">>}]),
                   parse('from', <<"<sip:bob@biloxi.com>;tag=1928301774">>)),
     ?_assertEqual(address(<<"Bob Zert">>, <<"sip:bob@biloxi.com">>, [{'tag', <<"1928301774">>}]),
                   parse('from', <<"\"Bob Zert\" <sip:bob@biloxi.com>;tag=1928301774">>)),

     ?_assertEqual(<<"\"Bob  Zert\" <sip:bob@biloxi.com>;tag=1928301774">>,
                   format('from', address(<<"Bob  Zert">>, <<"sip:bob@biloxi.com">>, [{'tag', <<"1928301774">>}]))),
     ?_assertEqual(<<"<sip:bob@biloxi.com>;tag=1928301774">>,
                   format('from', address(<<>>, <<"sip:bob@biloxi.com">>, [{'tag', <<"1928301774">>}]))),
     ?_assertEqual(<<"<sip:bob@biloxi.com>;tag=1928301774">>,
                   format('from', address(<<>>, <<"sip:bob@biloxi.com">>, [{'tag', <<"1928301774">>}]))),
     ?_assertEqual(<<"\"Bob Zert\" <sip:bob@biloxi.com>;tag=1928301774">>,
                   format('from', address(<<"Bob Zert">>, <<"sip:bob@biloxi.com">>, [{'tag', <<"1928301774">>}]))),

     % In-Reply-To
     ?_assertEqual([<<"70710@saturn.bell-tel.com">>, <<"17320@saturn.bell-tel.com">>],
                   parse('in-reply-to', <<"70710@saturn.bell-tel.com, 17320@saturn.bell-tel.com">>)),
     ?_assertEqual(<<"70710@saturn.bell-tel.com, 17320@saturn.bell-tel.com">>,
                   format('in-reply-to', [<<"70710@saturn.bell-tel.com">>, <<"17320@saturn.bell-tel.com">>])),

     % Max-Forwards
     ?_assertEqual(70, parse('max-forwards', <<"70">>)),
     ?_assertEqual(<<"70">>, format('max-forwards', 70)),

     % Min-Expires
     ?_assertEqual(213, parse('min-expires', <<"213">>)),
     ?_assertEqual(<<"213">>, format('min-expires', 213)),



     % To
     ?_assertEqual(address(<<"Bob Zert">>, <<"sip:bob@biloxi.com">>, [{'tag', <<"1928301774">>}]),
                   parse('to', <<"\"Bob Zert\" <sip:bob@biloxi.com>;tag=1928301774">>)),
     ?_assertEqual(address(<<"Bob \"Zert">>, <<"sip:bob@biloxi.com">>, [{'tag', <<"1928301774">>}]),
                   parse('to', <<"\"Bob \\\"Zert\" <sip:bob@biloxi.com>;tag=1928301774">>)),

     ?_assertEqual(<<"\"Bob Zert\" <sip:bob@biloxi.com>;tag=1928301774">>,
                   format('to', address(<<"Bob Zert">>, <<"sip:bob@biloxi.com">>, [{'tag', <<"1928301774">>}]))),
     ?_assertEqual(<<"\"Bob \\\"Zert\" <sip:bob@biloxi.com>;tag=1928301774">>,
                   format('to', address(<<"Bob \"Zert">>, <<"sip:bob@biloxi.com">>, [{'tag', <<"1928301774">>}]))),



     % Route, Record-Route
     ?_assertEqual([address(<<>>, <<"sip:p1.example.com;lr">>, [])],
                   parse('route', <<"<sip:p1.example.com;lr>">>)),
     ?_assertEqual([address(<<>>, <<"sip:p1.example.com;lr">>, [])],
                   parse('record-route', <<"<sip:p1.example.com;lr>">>)),

     ?_assertEqual(<<"<sip:p1.example.com;lr>">>,
                   format('route', address(<<>>, <<"sip:p1.example.com;lr">>, []))),
     ?_assertEqual(<<"<sip:p1.example.com;lr>">>,
                   format('record-route', address(<<>>, <<"sip:p1.example.com;lr">>, []))),

     % Via
     ?_assertEqual([via(udp, {{8193,3512,0,0,0,0,44577,44306}, undefined}, [{branch, <<"z9hG4bK776asdhds">>}])],
                   parse('via', <<"SIP/2.0/UDP [2001:0db8:0000:0000:0000:0000:ae21:ad12];branch=z9hG4bK776asdhds">>)),
     ?_assertEqual([via(udp, {"pc33.atlanta.com", undefined}, [{branch, <<"z9hG4bK776asdhds">>}])],
                   parse('via', <<"SIP/2.0/UDP pc33.atlanta.com;branch=z9hG4bK776asdhds">>)),
     ?_assertEqual([via(udp, {"pc33.atlanta.com", undefined}, [{branch, <<"z9hG4bK776asdhds">>}])],
                   parse('via', <<"SIP/2.0/UDP pc33.atlanta.com ; branch=z9hG4bK776asdhds">>)),
     ?_assertEqual([via(udp, {{127, 0, 0, 1}, 15060}, [{param, <<"value">>}, flag]),
                    via(tcp, {"pc33.atlanta.com", undefined}, [{branch, <<"z9hG4bK776asdhds">>}])],
                   parse('via', <<"SIP/2.0/UDP 127.0.0.1:15060;param=value;flag,SIP/2.0/TCP pc33.atlanta.com;branch=z9hG4bK776asdhds">>)),
     ?_assertEqual([via(udp, {{127, 0, 0, 1}, 15060}, [{param, <<"value">>}, flag]),
                    via(tcp, {"pc33.atlanta.com", undefined}, [{branch, <<"z9hG4bK776asdhds">>}]),
                    via(udp, {"pc22.atlanta.com", undefined}, [{branch, <<"z9hG4bK43nthoeu3">>}])],
                   parse('via', <<"SIP/2.0/UDP 127.0.0.1:15060;param=value;flag,SIP/2.0/TCP pc33.atlanta.com;branch=z9hG4bK776asdhds,SIP/2.0/UDP pc22.atlanta.com;branch=z9hG4bK43nthoeu3">>)),
     ?_assertEqual(<<"SIP/2.0/UDP pc33.atlanta.com;branch=z9hG4bK776asdhds">>,
                   format('via', [via(udp, {"pc33.atlanta.com", undefined}, [{branch, <<"z9hG4bK776asdhds">>}])])),
     ?_assertEqual(<<"SIP/2.0/UDP 127.0.0.1:15060;param=value;flag, SIP/2.0/TCP pc33.atlanta.com:5060;branch=z9hG4bK776asdhds">>,
                   format('via', [via(udp, {{127, 0, 0, 1}, 15060}, [{param, <<"value">>}, flag]),
                                         via(tcp, "pc33.atlanta.com", [{branch, <<"z9hG4bK776asdhds">>}])])),
     ?_assertEqual(<<"SIP/2.0/UDP 127.0.0.1:15060;param=value;flag">>,
                   format('via', <<"SIP/2.0/UDP 127.0.0.1:15060;param=value;flag">>)),
     ?_assertEqual(<<"SIP/2.0/UDP pc33.atlanta.com;extra=\"Hello world\"">>,
                   format('via', [via(udp, {"pc33.atlanta.com", undefined}, [{extra, <<"Hello world">>}])])),
     ?_assertEqual([via(udp, {"pc33.atlanta.com", undefined}, [{ttl, 3}, {maddr, {224, 0, 0, 1}}, {received, {127, 0, 0, 1}}, {branch, <<"z9hG4bK776asdhds">>}])],
                   parse('via', <<"SIP/2.0/UDP pc33.atlanta.com;ttl=3;maddr=224.0.0.1;received=127.0.0.1;branch=z9hG4bK776asdhds">>)),
     ?_assertEqual([via(udp, {"pc33.atlanta.com", undefined}, [{ttl, 3}, {maddr, "sip.mcast.net"}, {received, {127, 0, 0, 1}}, {branch, <<"z9hG4bK776asdhds">>}])],
                   parse('via', <<"SIP/2.0/UDP pc33.atlanta.com;ttl=3;maddr=sip.mcast.net;received=127.0.0.1;branch=z9hG4bK776asdhds">>)),

     % Require, Proxy-Require, Supported, Unsupported
     ?_assertEqual([foo, bar], parse('require', <<"foo, bar">>)),
     ?_assertEqual(<<"foo, bar">>, format('require', [foo, bar])),

     ?_assertEqual([foo, bar], parse('proxy-require', <<"foo, bar">>)),
     ?_assertEqual(<<"foo, bar">>, format('proxy-require', [foo, bar])),

     ?_assertEqual([foo, bar], parse('supported', <<"foo, bar">>)),
     ?_assertEqual(<<"foo, bar">>, format('supported', [foo, bar])),

     ?_assertEqual([foo, bar], parse('unsupported', <<"foo, bar">>)),
     ?_assertEqual(<<"foo, bar">>, format('unsupported', [foo, bar])),

     % If the URI is not enclosed in angle brackets, any semicolon-delimited
     % parameters are header-parameters, not URI parameters, Section 20.
     ?_assertEqual({address(<<>>,
                            sip_uri:parse(<<"sip:alice@atlanta.com">>),
                            [{param, <<"value">>}]),
                    <<>>},
                   parse_address(<<"sip:alice@atlanta.com;param=value">>, fun parse_generic_param/2)),

     % Subject (FIXME: implement proper tests)
     ?_assertEqual(<<"I know you're there, pick up the phone and talk to me!">>,
        format('subject', <<"I know you're there, pick up the phone and talk to me!">>))
    ].

-spec utility_test_() -> list().
utility_test_() ->
    URI = sip_uri:parse(<<"sip:example.com">>),
    [
     ?_assertEqual(address(<<>>, URI, [{tag, <<"123456">>}]), add_tag('to', address(<<>>, URI, []), <<"123456">>))
     ].

-endif.
