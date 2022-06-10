const std = @import("std");
const network = @import("network");
const net = std.net;
const Md5 = std.crypto.hash.Md5;
const ArrayList = std.ArrayList;
const cAllocator = std.heap.c_allocator;

const packedInt32 = std.PackedIntArrayEndian(i32, .Big, 1);
const packedInt16 = std.PackedIntArrayEndian(i16, .Big, 1);

pub const SqlColumn = struct {
    const Self = @This();

    columnName: ArrayList(u8),
    dataType: i32,

    pub fn init() Self {
        return .{
            .columnName = ArrayList(u8).init(cAllocator),
            .dataType = 0,
        };
    }
};

pub const SqlRaw = struct {
    const Self = @This();
    fields: ArrayList([]const u8) = ArrayList([]const u8).init(cAllocator),

    pub fn deinit(self: Self) void{
        self.fields.deinit();
    }
};

pub const SqlRaws = struct {
    const Self = @This();

    sqlColumns: []SqlColumn,
    raws: ArrayList(SqlRaw),
    pub fn init(columns: []SqlColumn) Self {
        return .{
            .sqlColumns = columns,
            .raws = ArrayList(SqlRaw).init(cAllocator),
        };
    }

    pub fn deinit(self: Self) void{
        var i:i32 = 0;
        while (i < self.raws.items.len) {
            self.raws[i].deinit();
            i+=1;
        }
        self.raws.deinit();
    }
};

pub const SqlResult = struct {
    const Self = @This();

    sqlRaws: ?SqlRaws,
    sqlError: ?SqlError,

    pub fn init(raws: ?SqlRaws, sqlErr: ?SqlError) Self {
        return .{
            .sqlRaws = raws,
            .sqlError = sqlErr,
        };
    }
};

pub const SqlError = struct {
    const Self = @This();

    code: ArrayList(u8),
    message: ArrayList(u8),

    fn init() Self{
        return .{
            .code = ArrayList(u8).init(cAllocator),
            .message = ArrayList(u8).init(cAllocator),
        };
    }
};

pub const Kv = struct {
    const Self = @This();

    key: ArrayList(u8),
    val: ArrayList(u8),

    pub fn init() Self {
        return .{
            .key = ArrayList(u8).init(cAllocator),
            .val = ArrayList(u8).init(cAllocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.key.deinit();
        self.val.deinit();
    }
};

pub const Conn = struct {
    const Self = @This();
    var sock: network.Socket = undefined;
    var transactionStatusIndicator: u8 = undefined;
    var secretKey: i32 = undefined;
    var processID: i32 = undefined;
    var serverMetaData = ArrayList(Kv).init(cAllocator);

    host: []const u8,
    port: u16,
    user: []const u8,
    password: []const u8,
    database: []const u8,

    pub fn connect(
        conn: *Self,
        name: []const u8,
        port: u16,
    ) !void {
        sock = try network.connectToHost(std.heap.page_allocator, name, port, .tcp);
        try conn.sendStartupMessage();
        try conn.authPipeline();
    }

    pub fn deinit(_: *Self) void {
        var i:u32 = 0;
        while (i < serverMetaData.items.len) {
            serverMetaData.items[i].deinit();
            i+=1;
        }
        serverMetaData.deinit();
        sock.close();
    }

    pub fn copy(conn: *Self, sql: []const u8, inputData: []u8) !void {
        var sqlError: ?SqlError = null;        
        var res: ArrayList(u8) = ArrayList(u8).init(cAllocator);
        try conn.sendQuery(sql);
        while (true) {
            var messageType = try sock.reader().readByte();
            var len = try sock.reader().readInt(i32, .Big);
            len -= 4;

            // G
            if (messageType == 71) {
                // CopyInResponse (B)
                // Byte1('G')
                //     Identifies the message as a Start Copy In response. The frontend must now send copy-in data (if not prepared to do so, send a CopyFail message). 
                // Int32
                //     Length of message contents in bytes, including self. 
                // Int8
                //     0 indicates the overall COPY format is textual (rows separated by newlines, columns separated by separator characters, etc). 1 indicates the overall copy format is binary (similar to DataRow format). See COPY for more information. 
                // Int16
                //     The number of columns in the data to be copied (denoted N below). 
                // Int16[N]
                //     The format codes to be used for each column. Each must presently be zero (text) or one (binary). All must be zero if the overall copy format is textual. 
                _ = try sock.reader().readInt(i8, .Big);

                var lcolumn = try sock.reader().readInt(i16, .Big);

                var i: i32 = 0;
                while (i < lcolumn) {
                    _ = try sock.reader().readInt(i16, .Big);
                    i += 1;
                }
                
                if (inputData.len > 0) {
                    try conn.sendCopyData(inputData);
                    try conn.sendCopyDone();
                }
            }

            // H
            if (messageType == 72) {
                // CopyOutResponse (B) 
                // Byte1('H')
                //     Identifies the message as a Start Copy Out response. This message will be followed by copy-out data. 
                // Int32
                //     Length of message contents in bytes, including self. 
                // Int8
                //     0 indicates the overall COPY format is textual (rows separated by newlines, columns separated by separator characters, etc). 1 indicates the overall copy format is binary (similar to DataRow format). See COPY for more information. 
                // Int16
                //     The number of columns in the data to be copied (denoted N below). 
                // Int16[N]
                //     The format codes to be used for each column. Each must presently be zero (text) or one (binary). All must be zero if the overall copy format is textual. 
                var format = try sock.reader().readInt(i8, .Big);
                std.debug.print("format: {d}\n", .{format});

                var lcolumn = try sock.reader().readInt(i16, .Big);
                var i: i32 = 0;
                while (i < lcolumn) {
                    var columnFormat = try sock.reader().readInt(i16, .Big);
                    std.debug.print("columnFormat: {d}\n", .{columnFormat});
                    i += 1;
                }
            }

            // d
            if (messageType == 100) {
                // CopyData (F & B)
                // Byte1('d')
                //     Identifies the message as COPY data. 
                // Int32
                //     Length of message contents in bytes, including self. 
                // Byten
                //     Data that forms part of a COPY data stream. Messages sent from the backend will always correspond to single data rows, but messages sent by frontends might divide the data stream arbitrarily. 
                var data = try conn.readMessageN(len);
                try res.appendSlice(data);
            }

            // c
            if (messageType == 99) {
                // CopyDone (F & B)
                // Byte1('c')
                //     Identifies the message as a COPY-complete indicator. 
                // Int32(4)
                //     Length of message contents in bytes, including self. 
            }

            // E
            if (messageType == 69) {
                sqlError = SqlError.init();
                try conn.readSqlError(&sqlError.?);
            }

            // C
            if (messageType == 67) {
                // CommandComplete
                // Byte1('C')
                //      Identifies the message as a command-completed response.
                // Int32
                //      Length of message contents in bytes, including self.
                // String
                //      The command tag. This is usually a single word that identifies which SQL command was completed.

                _ = try conn.readMessageN(len);
            }

            // 'Z'
            if (messageType == 90) {
                // ReadyForQuery
                // Byte1('Z')
                //      Identifies the message type. ReadyForQuery is sent whenever the backend is ready for a new query cycle.
                // Int32(5)
                //      Length of message contents in bytes, including self.
                // Byte1
                //      Current backend transaction status indicator. Possible values are 'I' if idle (not in a transaction block); 'T' if in a transaction block; or 'E' if in a failed transaction block (queries will be rejected until block is ended).
                transactionStatusIndicator = try sock.reader().readByte();
                break;
            }
        }
        std.debug.print("res: {s}\n", .{res.items});
    }

    pub fn asyncQ(conn: *Self) !void {
        try conn.sendQuery("LISTEN ttt");

        while (true) {
            var messageType = try sock.reader().readByte();
            var len = try sock.reader().readInt(i32, .Big);
            len -= 4;
            if (messageType == 67) {
                // column values
                var v = try conn.readMessageN(len);
                std.debug.print("{s}\n", .{v});
            }
            if (messageType == 65) {
                var maxSize: u32 = @intCast(u32, len);

                var pid = try sock.reader().readInt(i32, .Big);
                std.debug.print("pid: {d}\n", .{pid});

                var list = std.ArrayList(u8).init(cAllocator);
                defer list.deinit();

                try sock.reader().readUntilDelimiterArrayList(&list, "\x00"[0], maxSize);
                std.debug.print("channel: {s}\n", .{list.items});

                try sock.reader().readUntilDelimiterArrayList(&list, "\x00"[0], maxSize);
                std.debug.print("payload: {s}\n", .{list.items});
            }

            // 'Z'
            if (messageType == 90) {
                _ = try sock.reader().readByte();
            }
        }
    }

    pub fn query(conn: *Self, sql: []const u8) !SqlResult {
        var sqlRaws: ?SqlRaws = null;
        var sqlError: ?SqlError = null;
        try conn.sendQuery(sql);
        while (true) {
            var messageType = try sock.reader().readByte();
            var len = try sock.reader().readInt(i32, .Big);
            len -= 4;

            // T
            if (messageType == 84) {
                sqlRaws = try conn.rowDescription();
            }

            // E
            if (messageType == 69) {
                sqlError = SqlError.init();
                try conn.readSqlError(&sqlError.?);
            }

            // N
            if (messageType == 78) {
                var code = try sock.reader().readByte();
                if (code != 0) {
                    sqlError = SqlError.init();
                    try conn.readSqlError(&sqlError.?);
                }
            }

            // D
            if (messageType == 68) {
                try conn.readDataRow(&sqlRaws.?);
            }

            // C
            if (messageType == 67) {
                // CommandComplete
                // Byte1('C')
                //      Identifies the message as a command-completed response.
                // Int32
                //      Length of message contents in bytes, including self.
                // String
                //      The command tag. This is usually a single word that identifies which SQL command was completed.
                _ = try conn.readMessageN(len);
            }

            // 'Z'
            if (messageType == 90) {
                // ReadyForQuery
                // Byte1('Z')
                //      Identifies the message type. ReadyForQuery is sent whenever the backend is ready for a new query cycle.
                // Int32(5)
                //      Length of message contents in bytes, including self.
                // Byte1
                //      Current backend transaction status indicator. Possible values are 'I' if idle (not in a transaction block); 'T' if in a transaction block; or 'E' if in a failed transaction block (queries will be rejected until block is ended).
                transactionStatusIndicator = try sock.reader().readByte();
                break;
            }
        }

        if (sqlError != null) {
            return SqlResult.init(null, sqlError);
        }
        return SqlResult.init(sqlRaws, null);
    }

    pub fn execute(conn: *Self, name: []const u8, sql: []const u8, params: []i32) !void {
        var sqlError: ?SqlError = null;

        try conn.sendParseMessage(name, sql, params);
        try conn.sendBindMessage("p1", "q1", params);
        try conn.sendExecuteMessage("p1", 0);
        try conn.sendSyncMessage();
        while (true) {
            var messageType = try sock.reader().readByte();
            var len = try sock.reader().readInt(i32, .Big);
            len -= 4;

            // 1
            if (messageType == 49) {
                // ParseComplete (B)
                // Byte1('1')
                //     Identifies the message as a Parse-complete indicator.
                // Int32(4)
                //     Length of message contents in bytes, including self.
            }

            // 2
            if (messageType == 50) {
                // BindComplete (B)
                // Byte1('2')
                //     Identifies the message as a Bind-complete indicator.
                // Int32(4)
                //     Length of message contents in bytes, including self.
            }

            if (messageType == 68) {
                var numberOfColumns = try sock.reader().readInt(i16, .Big);
                var i: u32 = 0;
                while (i < numberOfColumns) {
                    var lenOfColumnValue = try sock.reader().readInt(i32, .Big);
                    var fieldValue = try conn.readMessageN(lenOfColumnValue);
                    std.debug.print("lenOfColumnValue: {d}\n", .{lenOfColumnValue});
                    std.debug.print("fieldValue: {s}\n", .{fieldValue.items});
                    i += 1;
                }
            }

            if (messageType == 69) {
                sqlError = SqlError.init();
                try conn.readSqlError(&sqlError.?);
                std.debug.print("code {s}\n", .{sqlError.?.code.items});
                std.debug.print("message {s}\n", .{sqlError.?.message.items});
            }

            if (messageType == 67) {
                // column values
                var v = try conn.readMessageN(len);
                std.debug.print("{s}\n", .{v});
            }
            if (messageType == 90) {
                transactionStatusIndicator = try sock.reader().readByte();
                break;
            }
        }
    }

    ///StartupMessage (F)
    ///Int32
    ///    Length of message contents in bytes, including self. 
    ///Int32(196608)
    ///    The protocol version number. The most significant 16 bits are the major version number (3 for the protocol described here). The least significant 16 bits are the minor version number (0 for the protocol described here). 
    ///The protocol version number is followed by one or more pairs of parameter name and value strings. A zero byte is required as a terminator after the last name/value pair. Parameters can appear in any order. user is required, others are optional. Each parameter is specified as:
    ///String
    ///    The parameter name. Currently recognized names are:
    ///    user
    ///        The database user name to connect as. Required; there is no default. 
    ///    database
    ///        The database to connect to. Defaults to the user name. 
    ///    options
    ///        Command-line arguments for the backend. (This is deprecated in favor of setting individual run-time parameters.) Spaces within this string are considered to separate arguments, unless escaped with a backslash (\); write \\ to represent a literal backslash. 
    ///    In addition to the above, other parameters may be listed. Parameter names beginning with _pq_. are reserved for use as protocol extensions, while others are treated as run-time parameters to be set at backend start time. Such settings will be applied during backend start (after parsing the command-line arguments if any) and will act as session defaults. 
    ///String
    ///    The parameter value. 
    fn sendStartupMessage(conn: *Self) !void {
        var dataLen: i32 = 5 + @intCast(i32, conn.user.len) + 1 + 9 + @intCast(i32, conn.database.len) + 2;
        var len: i32 = @intCast(i32, dataLen + 4 + 4);
        try sock.writer().writeInt(i32, len, .Big);
        try sock.writer().writeInt(i32, 196608, .Big);
        try sock.writer().writeAll("user\x00");
        try sock.writer().writeAll(conn.user);
        try sock.writer().writeAll("\x00");
        try sock.writer().writeAll("database\x00");
        try sock.writer().writeAll(conn.database);
        try sock.writer().writeAll("\x00\x00");
    }

    fn sendPasswordMessage(conn: *Self, salt: [4]u8) !void {
        var forHash = try std.fmt.allocPrint(cAllocator, "{s}{s}", .{conn.user, conn.password});
        defer cAllocator.free(forHash);

        var hashedPassword: [16]u8 = undefined;
        var hexedHash: [32]u8 = undefined;

        Md5.hash(forHash, hashedPassword[0..], .{});
        const hexedStep1 = try std.fmt.bufPrint(&hexedHash, "{}", .{std.fmt.fmtSliceHexLower(&hashedPassword)});
        forHash = try std.fmt.allocPrint(cAllocator, "{s}{s}", .{hexedStep1, salt[0..]});
        Md5.hash(forHash, hashedPassword[0..], .{});
        const hexedStep2 = try std.fmt.bufPrint(&hexedHash, "{}", .{std.fmt.fmtSliceHexLower(&hashedPassword)});

        try sock.writer().writeAll("p");
        var len: i32 = @intCast(i32, hexedStep2.len + 3 + 1 + 4);
        try sock.writer().writeInt(i32, len, .Big);
        try sock.writer().writeAll("md5");
        try sock.writer().writeAll(hexedStep2);
        try sock.writer().writeAll("\x00");
    }

    ///Query (F)
    ///Byte1('Q')
    ///    Identifies the message as a simple query. 
    ///Int32
    ///    Length of message contents in bytes, including self. 
    ///String
    ///    The query string itself. 
    fn sendQuery(_: *Self, sql: []const u8) !void {
        try sock.writer().writeAll("Q");
        var len: i32 = @intCast(i32, sql.len + 4 + 1);
        try sock.writer().writeInt(i32, len, .Big);
        try sock.writer().writeAll(sql);
        try sock.writer().writeAll("\x00");
    }

    ///Parse (F)
    ///Byte1('P')
    ///    Identifies the message as a Parse command. 
    ///Int32
    ///    Length of message contents in bytes, including self. 
    ///String
    ///    The name of the destination prepared statement (an empty string selects the unnamed prepared statement). 
    ///String
    ///    The query string to be parsed. 
    ///Int16
    ///    The number of parameter data types specified (can be zero). Note that this is not an indication of the number of parameters that might appear in the query string, only the number that the frontend wants to prespecify types for. 
    ///Then, for each parameter, there is the following:
    ///Int32
    ///    Specifies the object ID of the parameter data type. Placing a zero here is equivalent to leaving the type unspecified. 
    fn sendParseMessage(_: *Self, name: []const u8, sql: []const u8, params: []i32) !void {
        try sock.writer().writeAll("P");
        var len: i32 = @intCast(i32, 4 + name.len + 1 + sql.len + 1 + 2 + params.len * 4);
        try sock.writer().writeInt(i32, len, .Big);
        try sock.writer().writeAll(name);
        try sock.writer().writeAll("\x00");
        try sock.writer().writeAll(sql);
        try sock.writer().writeAll("\x00");
        var paramsLen: i16 = @intCast(i16, params.len);
        try sock.writer().writeInt(i16, paramsLen, .Big);

        var i: u32 = 0;
        while (i < paramsLen) {
            try sock.writer().writeInt(i32, params[i], .Big);
            i += 1;
        }
    }

    ///Bind (F)
    ///Byte1('B')
    ///    Identifies the message as a Bind command. 
    ///Int32
    ///    Length of message contents in bytes, including self. 
    ///String
    ///    The name of the destination portal (an empty string selects the unnamed portal). 
    ///String
    ///    The name of the source prepared statement (an empty string selects the unnamed prepared statement). 
    ///Int16
    ///    The number of parameter format codes that follow (denoted C below). This can be zero to indicate that there are no parameters or that the parameters all use the default format (text); or one, in which case the specified format code is applied to all parameters; or it can equal the actual number of parameters. 
    ///Int16[C]
    ///    The parameter format codes. Each must presently be zero (text) or one (binary). 
    ///Int16
    ///    The number of parameter values that follow (possibly zero). This must match the number of parameters needed by the query. 
    ///Next, the following pair of fields appear for each parameter:
    ///Int32
    ///    The length of the parameter value, in bytes (this count does not include itself). Can be zero. As a special case, -1 indicates a NULL parameter value. No value bytes follow in the NULL case. 
    ///Byten
    ///    The value of the parameter, in the format indicated by the associated format code. n is the above length. 
    ///After the last parameter, the following fields appear:
    ///Int16
    ///    The number of result-column format codes that follow (denoted R below). This can be zero to indicate that there are no result columns or that the result columns should all use the default format (text); or one, in which case the specified format code is applied to all result columns (if any); or it can equal the actual number of result columns of the query. 
    ///Int16[R]
    ///    The result-column format codes. Each must presently be zero (text) or one (binary). 
    fn sendBindMessage(_: *Self, portalName: []const u8, queryName: []const u8, params: []i32) !void {
        try sock.writer().writeAll("B");
        try sock.writer().writeInt(i32, 30, .Big);
        try sock.writer().writeAll(portalName);
        try sock.writer().writeAll("\x00");
        try sock.writer().writeAll(queryName);
        try sock.writer().writeAll("\x00");

        var paramsLen: i16 = @intCast(i16, params.len);
        var columsCodesFormatLen: i32 = @intCast(i32, 12); //value
        var columsCodesFormat: i16 = @intCast(i16, 2);
        var paramsCodesFormat: i16 = @intCast(i16, 1);

        // params formats
        var i16_0: i16 = @intCast(i16, 0);
        var i32_4: i16 = @intCast(i32, 4);

        // params format
        try sock.writer().writeInt(i16, paramsLen, .Big);
        try sock.writer().writeInt(i16, paramsCodesFormat, .Big);

        // params values
        try sock.writer().writeInt(i16, paramsLen, .Big);

        try sock.writer().writeInt(i32, i32_4, .Big);
        try sock.writer().writeInt(i32, columsCodesFormatLen, .Big);

        // COLUMNS
        try sock.writer().writeInt(i16, columsCodesFormat, .Big);
        try sock.writer().writeInt(i16, i16_0, .Big);
        try sock.writer().writeInt(i16, i16_0, .Big);
    }

    ///Execute (F)
    ///Byte1('E')
    ///    Identifies the message as an Execute command. 
    ///Int32
    ///    Length of message contents in bytes, including self. 
    ///String
    ///    The name of the portal to execute (an empty string selects the unnamed portal). 
    ///Int32
    ///    Maximum number of rows to return, if portal contains a query that returns rows (ignored otherwise). Zero denotes “no limit”. 
    fn sendExecuteMessage(_: *Self, portalName: []const u8, maxRows: i32) !void {
        try sock.writer().writeAll("E");
        var len: i32 = @intCast(i32, portalName.len + 1 + 4 + 4);
        try sock.writer().writeInt(i32, len, .Big);
        try sock.writer().writeAll(portalName);
        try sock.writer().writeAll("\x00");
        try sock.writer().writeInt(i32, maxRows, .Big);
    }

    ///Sync (F) 
    ///Byte1('S')
    ///    Identifies the message as a Sync command. 
    ///Int32(4)
    ///    Length of message contents in bytes, including self. 
    fn sendSyncMessage(_: *Self) !void {
        var req:[5]u8 = .{"S"[0], 0, 0, 0, 4};
        try sock.writer().writeAll(req[0..]);
    }

    ///CopyData (F & B)
    ///Byte1('d')
    ///    Identifies the message as COPY data. 
    ///Int32
    ///    Length of message contents in bytes, including self. 
    ///Byten
    ///    Data that forms part of a COPY data stream.
    //     Messages sent from the backend will always correspond to single data rows, but messages sent by frontends might divide the data stream arbitrarily. 
    fn sendCopyData(_: *Self, data: []u8) !void {
        try sock.writer().writeAll("d");
        var len: i32 = @intCast(i32, data.len + 4);
        try sock.writer().writeInt(i32, len, .Big);
        try sock.writer().writeAll(data);
    }

    ///CopyDone (F & B)
    ///Byte1('c')
    ///    Identifies the message as a COPY-complete indicator. 
    ///Int32(4)
    ///    Length of message contents in bytes, including self. 
    fn sendCopyDone(_: *Self) !void {
        var req:[5]u8 = .{"c"[0], 0, 0, 0, 4};
        try sock.writer().writeAll(req[0..]);
    }

    fn authenticationMD5Password(_: *Self) ![4]u8 {
        var salt = try sock.reader().readBytesNoEof(4);
        return salt;
    }

    fn sendAuthMessage(conn: *Self) !void {
        _ = try sock.reader().readInt(i32, .Big);
        var authType = try sock.reader().readInt(i32, .Big);
        if (authType == 5) {
            var salt = try conn.authenticationMD5Password();
            try conn.sendPasswordMessage(salt);
            return;
        }

        unreachable;
    }

    fn authPipeline(conn: *Self) !void {
        var messageType = try sock.reader().readByte();
        if (messageType != 82) {
            unreachable;
        }

        try conn.sendAuthMessage();
        while (true) {
            messageType = try sock.reader().readByte();
            var len = try sock.reader().readInt(i32, .Big);
            len -= 4;

            // 'R'
            if (messageType == 82) {
                var success = try sock.reader().readInt(i32, .Big);
                if (success != 0) {
                    unreachable;
                }
            }

            // 'S'
            if (messageType == 83) {
                var maxSize: u32 = @intCast(u32, len);
                var kv = Kv.init();
                try sock.reader().readUntilDelimiterArrayList(&kv.key, "\x00"[0], maxSize);
                try sock.reader().readUntilDelimiterArrayList(&kv.val, "\x00"[0], maxSize);
                try serverMetaData.append(kv);
            }

            // 'K'
            if (messageType == 75) {
                processID = try sock.reader().readInt(i32, .Big);
                secretKey = try sock.reader().readInt(i32, .Big);
            }

            // 'Z'
            if (messageType == 90) {
                transactionStatusIndicator = try sock.reader().readByte();
                break;
            }
        }
    }

    /// ErrorResponse (B)
    /// Byte1('E')
    ///     Identifies the message as an error.
    /// Int32
    ///     Length of message contents in bytes, including self.
    /// The message body consists of one or more identified fields, followed by a zero byte as a terminator. Fields can appear in any order. For each field there is the following:
    /// Byte1
    ///     A code identifying the field type; if zero, this is the message terminator and no string follows.
    /// String
    ///     The field value.
    fn readSqlError(_: Self, sqlError: *SqlError) !void {
        const delimiter: u8 = "\x00"[0];

        while (true) {
            var messageType = try sock.reader().readByte();
            if (messageType == delimiter) {
                break;
            }
            // var err = try conn.readMessageUntilDelimiter(delimiter);
            switch (messageType) {
                // M
                // Message: the primary human-readable error message. This should be accurate but terse (typically one line). Always present.
                77 => {
                    try sock.reader().readUntilDelimiterArrayList(&sqlError.message, delimiter, 100000);
                },
                // C
                // Code: the SQLSTATE code for the error (see Appendix A). Not localizable. Always present.
                67 => {
                    try sock.reader().readUntilDelimiterArrayList(&sqlError.code, delimiter, 100000);
                },
                else => {
                    var list = std.ArrayList(u8).init(cAllocator);
                    defer list.deinit();
                    try sock.reader().readUntilDelimiterArrayList(&list, delimiter, 100000);
                },
            }
        }

        return;
    }

    /// RowDescription
    /// Byte1('T')
    ///     Identifies the message as a row description.
    /// Int32
    ///     Length of message contents in bytes, including self.
    /// Int16
    ///     Specifies the number of fields in a row (can be zero).
    /// Then, for each field, there is the following:
    /// String
    ///     The field name.
    /// Int32
    ///     If the field can be identified as a column of a specific table, the object ID of the table; otherwise zero.
    /// Int16
    ///     If the field can be identified as a column of a specific table, the attribute number of the column; otherwise zero.
    /// Int32
    ///     The object ID of the field's data type.
    /// Int16
    ///     The data type size (see pg_type.typlen). Note that negative values denote variable-width types.
    /// Int32
    ///     The type modifier (see pg_attribute.atttypmod). The meaning of the modifier is type-specific.
    /// Int16
    ///     The format code being used for the field. Currently will be zero (text) or one (binary). In a RowDescription returned from the statement variant of Describe, the format code is not yet known and will always be zero.
    fn rowDescription(_: Self) !SqlRaws {
        var sqlColumns = ArrayList(SqlColumn).init(cAllocator);
        var numOfFields = try sock.reader().readInt(i16, .Big);
        var i: u32 = 0;
        while (i < numOfFields) {
            var sqlColumn = SqlColumn.init();
            try sock.reader().readUntilDelimiterArrayList(&sqlColumn.columnName, "\x00"[0], 100000);
            _ = try sock.reader().readInt(i32, .Big);
            _ = try sock.reader().readInt(i16, .Big);
            sqlColumn.dataType = try sock.reader().readInt(i32, .Big);
            _ = try sock.reader().readInt(i16, .Big);
            _ = try sock.reader().readInt(i32, .Big);
            _ = try sock.reader().readInt(i16, .Big);
            try sqlColumns.append(sqlColumn);
            i += 1;
        }

        var sqlRaws = SqlRaws.init(sqlColumns.items);
        return sqlRaws;
    }

    /// DataRow
    /// Byte1('D')
    ///     Identifies the message as a data row.
    /// Int32
    ///     Length of message contents in bytes, including self.
    /// Int16
    ///     The number of column values that follow (possibly zero).
    /// Next, the following pair of fields appear for each column:
    /// Int32
    ///     The length of the column value, in bytes (this count does not include itself). Can be zero. As a special case, -1 indicates a NULL column value. No value bytes follow in the NULL case.
    /// Byten
    ///     The value of the column, in the format indicated by the associated format code. n is the above length.
    fn readDataRow(conn: Self, sqlRaws: *SqlRaws) !void {
        var numberOfColumns = try sock.reader().readInt(i16, .Big);
        var i: u32 = 0;
        var raw: SqlRaw = SqlRaw{};
        while (i < numberOfColumns) {
            var lenOfColumnValue = try sock.reader().readInt(i32, .Big);
            var fieldValue = try conn.readMessageN(lenOfColumnValue);
            try raw.fields.append(fieldValue);
            i += 1;
        }
        try sqlRaws.raws.append(raw);
    }

    fn readMessageN(_: Self, num_size: i32) ![]u8 {
        var data = ArrayList(u8).init(cAllocator);
        var i: i32 = 0;

        while (i < num_size) {
            var b = try sock.reader().readByte();
            try data.append(b);
            i += 1;
        }
        return data.toOwnedSlice();
    }
};
