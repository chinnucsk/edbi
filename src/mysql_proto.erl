%%%-------------------------------------------------------------------
%% @copyright Geoff Cant
%% @author Geoff Cant <nem@erlang.geek.nz>
%% @version {@vsn}, {@date} {@time}
%% @doc MySQL Protocol encoding and decoding.
%% @end
%%%-------------------------------------------------------------------
-module(mysql_proto).

%% API
-export([decode/2
         ,encode/1
         ,encode_packet/2
         ,client_handshake/3
        ]).

-compile(export_all).

-include_lib("eunit/include/eunit.hrl").

-define(MYSQL_VERSION_10, 10).
-define(MYSQL_16MEG_PKT, 16777216).
-define(MYSQL_DEFAULT_CHARSET, 8).

%%====================================================================
%% Decoding
%%====================================================================

decode(packet, <<Length:24/little, SeqNo:8/little, Packet:Length/binary, Rest/binary>>) ->
    {packet, <<Length:24/little, SeqNo:8/little, Packet:Length/binary>>, Rest};
decode(Type, <<Length:24/little, SeqNo:8/little, Packet:Length/binary, Rest/binary>>) ->
    {packet, SeqNo, decode_packet(Type, Packet), Rest};
decode(_Type, Buf = <<Length:24/little, _SeqNo:8/little, _/binary>>) ->
    {incomplete, (Length + 4) - byte_size(Buf), Buf};
decode(_Type, Rest) ->
    {incomplete, Rest}.

decode_packet(server_handshake, <<?MYSQL_VERSION_10, Rest/binary>>) ->
    case decode_nullterm_string(Rest) of
        {ServerVersion,
         <<ThreadId:32/little,
          Scramble1:8/binary, 0,
          Capabilities:16/little,
          Lang:8/little,
          Status:16/little,
          _Filler:13/binary,
          Scramble2:13/binary>>} ->
            {server_handshake,
             [{vsn, ?MYSQL_VERSION_10},
              {thread_id, ThreadId},
              {server_vsn, ServerVersion},
              {scramble_buff, iolist_to_binary([Scramble1, Scramble2])},
              {server_capabilities, mysql_proto_constants:client_flags(Capabilities)},
              {language, Lang},
              {server_status, mysql_proto_constants:status_flags(Status)}]};
        Error ->
            throw({decode_error, Error})
    end;

decode_packet(client_handshake,
              <<ClientFlags:32/little,
               MaxPktSize:32/little,
               CharsetNo:8/little,
               _Filler:23/binary,
               Rest1/binary>>) ->
    Opts = [{client_flags, mysql_proto_constants:client_flags(ClientFlags)},
            {max_packet_size, MaxPktSize},
            {charset_no, CharsetNo}],
    case decode_nullterm_string(Rest1) of
        {UserName, <<>>} ->
            {client_handshake,
             Opts ++ [{username, UserName}]};
        {UserName, Rest2} ->
            case decode_lcb(Rest2) of
                {ScrambleBuff,<<>>} ->
                    {client_handshake,
                     Opts ++ [{username, UserName},
                              {scramble_buff, ScrambleBuff}]};
                {ScrambleBuff, <<0, Rest3/binary>>} ->
                    case decode_nullterm_string(Rest3) of
                        {DbName, <<>>} ->
                            {client_handshake,
                             Opts ++ [{username, UserName},
                                      {scramble_buff, ScrambleBuff},
                                      {db_name, DbName}]}
                    end
            end
    end;

decode_packet(command, <<Code:8/little, Rest/binary>>) ->
    Command = mysql_proto_constants:command(Code),
    {command, Command,
     decode_command(Command, Rest)};
decode_packet(response, <<16#ff, ErrNo:16/little, $\#,
                         SqlState:5/binary, Message/binary>>) ->
    {response, {error, mysql_proto_constants:error(ErrNo),
                SqlState, Message}};
decode_packet(response, <<16#ff, ErrNo:16/little, Message/binary>>) ->
    {response, {error, mysql_proto_constants:error(ErrNo),
                no_sqlstate, Message}};
decode_packet(response, <<0, Rest1/binary>>) ->
    {AffectedRows, Rest2} = decode_fle(Rest1),
    %% This is mysql4.1, decode 4.0?
    {InsertId, <<ServerStatus:16/little,
                Warnings:16/little,
                Message/binary>>} = decode_fle(Rest2),
    {response, ok, [{affected_rows, AffectedRows},
                    {insert_id, InsertId},
                    {server_status, mysql_proto_constants:status_flags(ServerStatus)},
                    {warning_count, Warnings},
                    {message, Message}]};
decode_packet(result_set_header, Rest1) ->
    case decode_fle(Rest1) of
        {FieldCount, <<>>} ->
            {result_set_header, FieldCount, no_extra};
        {FieldCount,Rest2} ->
            {Extra, <<>>} = decode_fle(Rest2),
            {result_set_header, FieldCount, Extra}
    end;

decode_packet(field, << 16#fe, Warnings:16/little,
                      ServerStatus:16/little>>) ->
    {end_of_fields, [{warnings, Warnings},
                     {server_status,
                      mysql_proto_constants:status_flags(ServerStatus)}]};
decode_packet(field, Rest1) ->
    {Rest2, Fields} = lists:foldl(fun (Field, {Bin, Acc}) ->
                                          {V,Rest} = decode_lcb(Bin),
                                          {Rest, [{Field, V}|Acc]}
                                  end,
                                  {Rest1, []},
                                  [catalog, db, table, org_table, name, org_name]),
    case Rest2 of
        <<_Filler:8,
         CharsetNo:16/little,
         Length:32/little,
         Type:8/little,
         Flags:16/little,
         Decimals:8/little,
         _Filler2:16,
         Default/binary>> ->
            {field, Fields ++
             [{charset_no, CharsetNo},
              {length, Length},
              {type, mysql_proto_constants:field_type(Type)},
              {flags, mysql_proto_constants:field_flags(Flags)},
              {decimals, Decimals}
              | case Default of
                    <<>> -> [];
                    _ ->
                        {D, <<>>} = decode_lcb(Default),
                        [{default, D}]
                end
             ]}
    end;

decode_packet(row, <<254, Warnings:16/little, Status:16/little>>) ->
    {row_eof, [{warnings, Warnings},
               {server_status, mysql_proto_constants:status_flags(Status)}]};
decode_packet(row, Values) ->
    {row, decode_row(decode_lcb(Values))}.

decode_row({V,<<>>}) ->
    [V];
decode_row({V, Rest}) ->
    [V] ++ decode_row(decode_lcb(Rest)).

decode_command(quit, <<>>) -> [];
decode_command(sleep, <<>>) -> [];
decode_command(init_db, <<DbName/binary>>) ->
    [{db_name, DbName}];
decode_command('query', <<SQL/binary>>) ->
    [{sql, SQL}];
decode_command(process_info, <<>>) -> [];
decode_command(statistics, <<>>) -> [];
decode_command(connect, <<>>) -> [];
decode_command(process_kill, <<ID:32/little>>) ->
    [{process_id, ID}].

%%====================================================================
%% Encoding
%%====================================================================

encode_packet(Seq, IoList) when is_list(IoList) ->
    encode_packet(Seq, iolist_to_binary(IoList));
encode_packet(Seq, Bin) when is_binary(Bin) ->
    <<(byte_size(Bin)):24/little, Seq:8/little, Bin/binary>>.

encode({server_handshake, Values}) ->
    <<Scramble1:8/binary,Scramble2/binary>> = proplists:get_value(scramble_buff,Values),
    [<<?MYSQL_VERSION_10>>,
     encode_nullterm_string(proplists:get_value(server_vsn,Values)),
     <<(proplists:get_value(thread_id,Values)):32/little>>,
     Scramble1, 
     0,
     <<(mysql_proto_constants:capabilities(proplists:get_value(server_capabilities,Values))):16/little>>,
     <<(proplists:get_value(language,Values)):8/little>>,
     <<(mysql_proto_constants:status(proplists:get_value(server_status,Values))):16/little>>,
     << 0:(8*13) >>,
     Scramble2];

encode({client_handshake, Values}) ->
    [<<(mysql_proto_constants:capabilities(proplists:get_value(client_flags,Values))):32/little>>,
     <<(proplists:get_value(max_packet_size,Values)):32/little>>,
     <<(proplists:get_value(charset_no,Values)):8/little>>,
     << 0:(8*23) >>,
     encode_nullterm_string(proplists:get_value(username,Values)),
     case proplists:get_value(scrambled_pass,Values) of
         %% If we don't have a scrambled pass, use the scramble_buff else
         %% return [] which will disappear when this iolist gets flattened.
         undefined ->
             case proplists:get_value(scramble_buff, Values) of
                 undefined -> [];
                 Buf -> encode_lcb(Buf)
             end;
         Pass -> encode_lcb(Pass)
     end,
     case proplists:get_value(dbname,Values) of
         DBName when is_list(DBName); is_binary(DBName) ->
             [0, encode_nullterm_string(DBName)];
         _ -> []
     end];

encode({command, Code, Options}) ->
    [mysql_proto_constants:command_code(Code)
     |encode_command(Code, Options)];
encode({response, {error, Error, no_sqlstate, Message}}) when is_atom(Error) ->
    [<<16#ff, (mysql_proto_constants:error_code(Error)):16/little,
      Message/binary>>];
encode({response, {error, Error, SqlState, Message}}) when is_atom(Error) ->
    [<<16#ff, (mysql_proto_constants:error_code(Error)):16/little,
      $\$, SqlState:5/binary, Message/binary>>];
encode({result_set_header, FieldCount, Extra}) ->
    [encode_fle(FieldCount), encode_fle(Extra)];
encode({field, _Values}) ->
    erlang:exit(nyi);
encode({row, Values}) ->
    [encode_lcb(V) || V <- Values].

client_handshake(Username, Password, Options) when is_list(Username) ->
    client_handshake(iolist_to_binary(Username), Password, Options);
client_handshake(Username, Password, Options) when is_list(Password) ->
    client_handshake(Username, iolist_to_binary(Password), Options);
client_handshake(Username, Password, Options) when is_binary(Username), is_binary(Password) ->
    ScrambleBuff = proplists:get_value(scramble_buff, Options),
    Flags = proplists:get_value(client_flags, Options, [long_password,
                                                        long_flags,
                                                        protocol_41,
                                                        transactions
                                                       ]),
    {client_handshake,
     [{client_flags, Flags},
      {max_packet_size, proplists:get_value(max_packet_size, Options, ?MYSQL_16MEG_PKT)},
      {charset_no, proplists:get_value(charset_no, Options, ?MYSQL_DEFAULT_CHARSET)},
      {username, Username},
      {scrambled_pass, scramble_password(ScrambleBuff,Password)}
      | case proplists:get_value(dbname, Options) of
            undefined -> [];
            V -> [{dbname, V}]
        end
     ]}.

encode_command(sleep, []) -> [];%server only
encode_command(quit, []) -> [];
encode_command(init_db, [{db_name, DB}])
  when is_list(DB); is_binary(DB) -> [DB];
encode_command('query', [{sql, SQL}])
  when is_list(SQL); is_binary(SQL) -> [SQL];
encode_command(field_list, _V) -> [];
encode_command(create_db, _V) -> [];%deprecated command
encode_command(drop_db, _V) -> [];%deprecated command
encode_command(refresh, _V) -> [];
encode_command(shutdown, _V) -> [];
encode_command(statistics, []) -> [];
encode_command(process_info, []) -> [];
encode_command(connect, []) -> [];%server only
encode_command(process_kill, [{process_id, ID}]) ->
    [<<ID:32/little>>];
encode_command(debug, _V) -> [];
encode_command(ping, _V) -> [];
encode_command(time, _V) -> [];%server only
encode_command(delayed_insert, _V) -> [];%server only
encode_command(change_user, V) ->
    [encode_nullterm_string(proplists:get_value(username, V)),
     encode_lcb(proplists:get_value(password, V)),
     encode_lcb(proplists:get_value(dbname, V)),
     case proplists:get_value(charset_no, V) of
         undefined -> [];
         N -> [<<N:16/little>>]
     end];
encode_command(binlog_dump, _V) -> [];
encode_command(table_dump, _V) -> [];
encode_command(connect_out, _V) -> [];%server only
encode_command(register_slave, _V) -> [];%server only
encode_command(stmt_prepare, _V) -> [];
encode_command(stmt_execute, _V) -> [];
encode_command(stmt_send_long_data, _V) -> [];
encode_command(stmt_close, _V) -> [];
encode_command(stmt_reset, _V) -> [];
encode_command(set_option, _V) -> [];
encode_command(stmt_fetch, _V) -> [].

%%====================================================================
%% Primitive type codec functions
%%====================================================================

decode_nullterm_string(Bin) ->
    decode_nullterm_string(Bin, 1).

decode_nullterm_string(Bin, Idx) ->
    case Bin of
        <<String:Idx/binary, 0, Rest/binary>> ->
            {String, Rest};
        _ when byte_size(Bin) > Idx ->
            decode_nullterm_string(Bin, Idx + 1)
    end.


encode_nullterm_string(Str) when is_list(Str); is_binary(Str) ->
    iolist_to_binary([Str, 0]).

encode_lcb(String) when is_list(String) ->
    encode_lcb(iolist_to_binary(String));
encode_lcb(null) ->
    <<251:8/little>>;
encode_lcb(Bin) when byte_size(Bin) =< 250 ->
    <<(byte_size(Bin)):8/little, Bin/binary>>;
encode_lcb(Bin) when byte_size(Bin) =< 65535 ->
    <<252:8/little, (byte_size(Bin)):16/little, Bin/binary>>;
encode_lcb(Bin) when byte_size(Bin) =< 16777215 ->
    <<253:8/little, (byte_size(Bin)):24/little, Bin/binary>>;
encode_lcb(Bin) when byte_size(Bin) > 16777215 ->
    <<254:8/little, (byte_size(Bin)):64/little, Bin/binary>>.

decode_lcb(<<Len:8/little, Data:Len/binary, Rest/binary>>) when Len =< 250 ->
    {Data, Rest};
decode_lcb(<<251:8/little, Rest/binary>>) ->
    {null, Rest};
decode_lcb(<<252, Len:16/little, Data:Len/binary, Rest/binary>>) when Len =< 65535 ->
    {Data, Rest};
decode_lcb(<<253, Len:24/little, Data:Len/binary, Rest/binary>>) when Len =< 16777215 ->
    {Data, Rest};
decode_lcb(<<254, Len:64/little, Data:Len/binary, Rest/binary>>) when Len > 16777215 ->
    {Data, Rest}.

encode_fle(Int) when Int =< 250 ->
    <<Int:8/little>>;
encode_fle(Int) when Int =< 65535 ->
    <<252, Int:16/little>>;
encode_fle(Int) when Int =< 16777215 ->
    <<253, Int:24/little>>;
encode_fle(Int) when Int > 16777215 ->
    <<254, Int:64/little>>.

decode_fle(<<Int:8/little, Rest/binary>>) when Int =< 250 ->
    {Int, Rest};
decode_fle(<<252, Int:16/little, Rest/binary>>) ->
    {Int, Rest};
decode_fle(<<253, Int:24/little, Rest/binary>>) ->
    {Int, Rest};
decode_fle(<<254, Int:64/little, Rest/binary>>) ->
    {Int, Rest}.

%%====================================================================
%% Password challenge-response calculation
%%====================================================================

scramble_password(<<ScrambleBuff:20/binary, 0>>, Password) when is_binary(Password) ->
    Stage1 = crypto:sha(Password),
    Stage2 = crypto:sha(Stage1),
    crypto:exor(Stage1, crypto:sha(<<ScrambleBuff/binary, Stage2/binary>>)).

%%====================================================================
%% Unit testing
%%====================================================================

example_mysql_server_handshake() ->
    <<52,0,0,0,10,53,46,48,46,52,53,0,44,0,0,0,120,42,98,51,
     116,111,83,49,0,44,162,8,2,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
     56,100,114,50,61,124,124,119,96,93,50,125,0>>.

example_mysql_server_handshake2() ->
    <<52,0,0,0,10,53,46,48,46,52,53,0,12,0,0,0,56,124,44,98,44,79,45,50,0,
     44,162,8,2,0,0,0,0,0,0,0,0,0,0,0,0,0,0,80,126,75,60,42,90,104,122,
     78,86,70,60,0>>.

example_scramble_buff() ->
    <<119,94,80,87,66,36,43,75,121,63,111,49,68,69,106,101,62,
     67,119,80,0>>.

example_scrambled_pass() ->
    <<250,250,28,1,178,179,188,240,224,6,40,213,32,38,142,14,
     69,236,160,21>>.

example_client_handshake() ->
    <<62,0,0,1,165,162,0,0,0,0,0,64,8,0,0,0,0,0,0,0,0,0,0,0,0,
     0,0,0,0,0,0,0,0,0,0,0,101,106,97,98,98,101,114,100,0,20,
     250,250,28,1,178,179,188,240,224,6,40,213,32,38,142,14,
     69,236,160,21>>.

example_client_handshake2() ->
    <<62,0,0,1,165,162,0,0,0,0,0,64,8,0,0,0,0,0,0,0,0,0,0,0,0,
     0,0,0,0,0,0,0,0,0,0,0,101,106,97,98,98,101,114,100,0,20,
     82,62,201,159,85,89,48,110,205,6,141,187,19,159,158,11,
     44,152,158,145>>.

example_ok_packet() ->
    <<7,0,0,2,0,0,0,2,0,0,0>>.

scramble_test() ->
    Bytes = example_scrambled_pass(),
    ?assertMatch(Bytes,
                 scramble_password(example_scramble_buff(), <<"ejabberd">>)).

client_handshake_test() ->
    Hsk = client_handshake("ejabberd", "ejabberd", [{scramble_buff, example_scramble_buff()},
                                                    {client_flags, [long_password,long_flags,
                                                                    compress,local_files,
                                                                    protocol_41,transactions,
                                                                    secure_connection]},
                                                    {max_packet_size, 1073741824}]),
    Pkt = encode(Hsk),
    Bytes = example_client_handshake(),
    ?assertMatch(Bytes, encode_packet(1, Pkt)).

server_handshake_test() ->
    Bytes = example_mysql_server_handshake(),
    ?assertMatch({packet, 0, {server_handshake, _Values}, <<>>},
                 decode(server_handshake, Bytes)),
    {packet, 0, Pkt, <<>>} = decode(server_handshake, example_mysql_server_handshake()),
    ?assertMatch(Bytes, encode_packet(0,encode(Pkt))).

lcb_test_() ->
    crypto:start(),
    lists:map(fun (Len) ->
                      Bytes = crypto:rand_bytes(Len),
                      Enc = encode_lcb(Bytes),
                      ?_assertMatch({Bytes, <<>>}, decode_lcb(Enc))
              end,
                  [1,2,249,250,251,65534,65535,65536]).
                   %%,16777215,16777216,16777217]).

lfe_test_() ->
    lists:map(fun (Int) ->
                      Enc = encode_fle(Int),
                      ?_assertMatch({Int, <<>>}, decode_fle(Enc))
              end,
              [1,2,249,250,251,65534,65535,65536
               ,16777215,16777216,16777217]).

simple_command_test_() ->
    lists:map(fun ({Cmd, Args}) ->
                          CmdT = {command, Cmd, Args},
                          Bytes = encode_packet(0, encode(CmdT)),
                          ?_assertMatch({packet, 0, CmdT, <<>>},
                                        decode(command, Bytes))
                  end,
                  [{sleep, []}, {quit, []},
                   {statistics, []}, {process_info, []},
                   {connect, []}, {process_kill, [{process_id, 1}]},
                   {'query', [{sql, <<"SELECT foo FROM bar">>}]},
                   {init_db, [{db_name, <<"proto">>}]}
                  ]).

response_test_() ->
    lists:map(fun (Code) ->
                      Resp = {response, {error, Code,
                                         no_sqlstate,
                                         iolist_to_binary("Error :" ++ atom_to_list(Code))}},
                      Bytes = encode_packet(0, encode(Resp)),
                      ?_assertMatch({packet, 0, Resp, <<>>},
                                    decode(response, Bytes))
              end,
              mysql_proto_constants:errors()).

result_set_header_test_() ->
    lists:map(fun ({Fields, Extra}) ->
                      Resp = {result_set_header, Fields, Extra},
                      Bytes = encode_packet(0, encode(Resp)),
                      ?_assertMatch({packet, 0, Resp, <<>>},
                                    decode(result_set_header, Bytes))
              end,
              [{A,B} || A <- lists:seq(1,10),
                        B <- lists:seq(0,2) ]).

reencode_test_() ->
    lists:map(fun ({Type, Bytes}) ->
                      {packet, Seq, Pkt, <<>>} = decode(Type, Bytes),
                      ?_assertMatch(Bytes,
                                    encode_packet(Seq, encode(Pkt)))
              end,
              [{client_handshake, example_client_handshake()},
               {client_handshake, example_client_handshake2()},
               {server_handshake, example_mysql_server_handshake()},
               {server_handshake, example_mysql_server_handshake2()}]).

row_test() ->
    Values = [ <<"One">>,
               <<"Two">>,
               <<"t">>,
               <<"three">> ],
    Enc = encode({row, Values}),
    ?assertMatch({row, Values},
                 decode_packet(row, iolist_to_binary(Enc))).
