const std = @import("std");
const network = @import("network");
const Md5 = std.crypto.hash.Md5;
const ArrayList = std.ArrayList;

pub fn concat(bufs: []const []const u8) ![]const u8 {
    return std.mem.concat(std.heap.c_allocator, u8, bufs);
}

const packedInt = std.PackedIntArrayEndian(i32, .Big, 1);

pub fn queryMessage(text: []const u8) ![]u8{
    var response = ArrayList(u8).init(std.heap.c_allocator);
    var len:i32 = @intCast(i32, text.len + 4 + 1);
    try response.appendSlice("Q");
    try response.appendSlice(&packedInt.initAllTo(len).bytes);
    try response.appendSlice(text);
    try response.appendSlice("\x00");
    return response.items;
}

pub fn authenticationRequest(user: []const u8, password: []const u8, reader: network.Socket.Reader) ![]u8 {
    _ = try reader.readInt(i32, .Big);
    var authType = try reader.readInt(i32, .Big);

    if (authType == 5) {
        var salt = try authenticationMD5Password(reader);
        return passwordMessage(user, password, salt);
    }

    unreachable;
}

pub fn authenticationMD5Password(reader: network.Socket.Reader) ![4]u8 {
    var salt = try reader.readBytesNoEof(4);
    return salt;
}

pub fn startupMessage(user: []const u8, database: []const u8) ![]u8 {
    var data = try concat(&[_][]const u8{"user\x00", user, "\x00" ,"database\x00", database, "\x00\x00" });
    defer std.heap.c_allocator.free(data);

    var response = ArrayList(u8).init(std.heap.c_allocator);
    var len:i32 = @intCast(i32, data.len + 4 + 4);
    try response.appendSlice(&packedInt.initAllTo(len).bytes);
    try response.appendSlice(&packedInt.initAllTo(196608).bytes);
    try response.appendSlice(data);
    return response.items;
}

pub fn passwordMessage(user: []const u8, password: []const u8, salt: [4]u8) ![]u8 {
    var forHash = try concat(&[_][]const u8{user, password});
    defer std.heap.c_allocator.free(forHash);

    var hashedPassword: [16]u8 = undefined;
    var hexedHash: [32]u8 = undefined;

    Md5.hash(forHash, hashedPassword[0..], .{});
    const hexedStep1 = try std.fmt.bufPrint(&hexedHash, "{}", .{std.fmt.fmtSliceHexLower(&hashedPassword)});

    forHash = try concat(&[_][]const u8{hexedStep1, &salt});
    Md5.hash(forHash, hashedPassword[0..], .{});

    const hexedStep2 = try std.fmt.bufPrint(&hexedHash, "{}", .{std.fmt.fmtSliceHexLower(&hashedPassword)});
    var data = try concat(&[_][]const u8{"md5", hexedStep2});

    var response = ArrayList(u8).init(std.heap.c_allocator);
    try response.appendSlice("p");
    var len:i32 = @intCast(i32, data.len+1+4);
    try response.appendSlice(&packedInt.initAllTo(len).bytes);
    try response.appendSlice(data);
    try response.appendSlice("\x00");

    return response.items;
}

pub const sqlColumn = struct {
    const Self = @This();

    columnName: []const u8,
    dataType: i32,

    pub fn init(columnName: []u8, dataType: i32) Self{
        return .{
            .columnName = columnName,
            .dataType = dataType,
        };
    }
};

pub const sqlRaw = struct {
    const Self = @This();
    fields: ArrayList([]const u8) = ArrayList([]const u8).init(std.heap.c_allocator),
};

pub const sqlRaws = struct {
    const Self = @This();

    sqlColumns: []sqlColumn,
    raws: ArrayList(sqlRaw) = ArrayList(sqlRaw).init(std.heap.c_allocator),
};

pub const Kv = struct {
    const Self = @This();

    key: []const u8,
    val: []const u8,

    pub fn init(key: []const  u8, val: []const u8) Self{
        return .{
            .key = key,
            .val = val,
        };
    }
};

pub const Conn = struct {
    const Self = @This();
    var sock: network.Socket = undefined;
    var transactionStatusIndicator: u8 = undefined;
    var secretKey:i32 = undefined;
    var processID: i32 = undefined;
    var serverMetaData = ArrayList(Kv).init(std.heap.c_allocator);

    host: []const u8,
    port: u16,
    user:  []const u8,
    password: []const u8,
    database: []const u8,

    pub fn connect(conn: *Self, name: []const u8, port: u16,) !void{
        sock = try network.connectToHost(std.heap.page_allocator, name, port, .tcp);
        var startup = try startupMessage(conn.user, conn.database);
        try sock.writer().writeAll(startup);

        try conn.authPipeline();
    }

    pub fn deinit(_: *Self) void{
        serverMetaData.clearAndFree();
        sock.close();
    }

    fn authPipeline(conn: *Self) !void{
        var messageType = try sock.reader().readByte();
        if (messageType != 82) {
            unreachable;
        }

        var req = try authenticationRequest(conn.user, conn.password, sock.reader());
        try sock.writer().writeAll(req);

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
                var key = try conn.readMessageUntilDelimiter("\x00"[0]);
                var val = try conn.readMessageUntilDelimiter("\x00"[0]);
                try serverMetaData.append(Kv.init(key, val));
                
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

    pub fn query(conn: *Self, sql: []const u8) !sqlRaws {
        var raws: sqlRaws = sqlRaws{
            .sqlColumns = undefined,
        };
        var sqlColumns = ArrayList(sqlColumn).init(std.heap.c_allocator);
        var req = try queryMessage(sql);
        try sock.writer().writeAll(req);

        while (true) {
            var messageType = try sock.reader().readByte();
            var len = try sock.reader().readInt(i32, .Big);
            len -=4;
            if (messageType == 84){                
                var numOfFields = try sock.reader().readInt(i16, .Big);

                var i: u32 = 0;
                while (i < numOfFields) {                    
                    var name = try conn.readMessageUntilDelimiter("\x00"[0]);

                    // If the field can be identified as a column of a specific table, the object ID of the table; otherwise zero.
                    _ = try sock.reader().readInt(i32, .Big);
                    // If the field can be identified as a column of a specific table, the attribute number of the column; otherwise zero.
                    _ = try sock.reader().readInt(i16, .Big);
                    // The object ID of the field's data type.
                    var dataType = try sock.reader().readInt(i32, .Big);
                    // The data type size (see pg_type.typlen).
                    // Note that negative values denote variable-width types.
                    _ = try sock.reader().readInt(i16, .Big);
                    // The type modifier (see pg_attribute.atttypmod).
                    // The meaning of the modifier is type-specific.
                    _ = try sock.reader().readInt(i32, .Big);
                    // The format code being used for the field.
                    // Currently will be zero (text) or one (binary).
                    // In a RowDescription returned from the statement variant of Describe, the format code is not yet known and will always be zero.
                    _ = try sock.reader().readInt(i16, .Big);
                    // raw =  ;
                    try sqlColumns.append(sqlColumn.init(name, dataType));
                    i += 1;
                }

                raws.sqlColumns = sqlColumns.items;
            }

            if (messageType == 69) {
                // TODO: PARSE ERROR
            }

            if (messageType == 68){
                var numberOfColumns = try sock.reader().readInt(i16, .Big);
                var i: u32 = 0;
                var raw: sqlRaw = sqlRaw{};
                while (i < numberOfColumns) {
                    var lenOfColumnValue = try sock.reader().readInt(i32, .Big);
                    var fieldValue = try conn.readMessageN(lenOfColumnValue);
                    try raw.fields.append(fieldValue);
                    i += 1;
                }
                try raws.raws.append(raw);
            }

            if (messageType == 67){
                // column values
                _ = try conn.readMessageN(len);
            }

            // 'Z'
            if (messageType == 90) {
                transactionStatusIndicator = try sock.reader().readByte();
                break;
            }
        }

        return raws;
    }

    fn readMessageN(_: Self, num_size: i32) ![]u8 {
        var data = ArrayList(u8).init(std.heap.c_allocator);
        var i: i32 = 0;

        while (i < num_size) {
            var b = try sock.reader().readByte();
            try data.append(b);
            i += 1;
        }
        return data.items;
    }

    fn readMessageUntilDelimiter(_: Self, delimiter: u8) ![]u8 {
        var data = ArrayList(u8).init(std.heap.c_allocator);
        var i: i32 = 0;

        while (true) {
            var b = try sock.reader().readByte();
            if (b == delimiter) {
                break;
            }
            try data.append(b);
            i += 1;
        }
        return data.items;
    }
};
