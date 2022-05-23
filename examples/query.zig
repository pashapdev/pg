const std = @import("std");
const network = @import("network");
const pg = @import("pg");

pub fn main() !void {
    var conn = pg.Conn{
        .host = "127.0.0.1",
        .port = 5433,
        .user = "postgres",
        .password = "postgres", 
        .database = "postgres"};

    try network.init();
    defer network.deinit();

    const sock = try network.connectToHost(std.heap.page_allocator, conn.host, conn.port, .tcp);
    defer sock.close();

    try conn.connect(conn.host, conn.port);
    defer conn.deinit();


    var q: []const u8 = "CREATE TABLE IF NOT EXISTS test_table1(id integer, name TEXT);";
    var res = try conn.query(q);
    printSqlResult(res);
    q = "insert into test_table1(id, name) values(1, 'name1')";
    res = try conn.query(q);
    printSqlResult(res);
    q = "insert into test_table1(id, name) values(2, 'name2')";
    res = try conn.query(q);
    printSqlResult(res);
    q = "select * from test_table1";
    res = try conn.query(q);
    printSqlResult(res);
    q = "select * fom test_table1";
    res = try conn.query(q);
    printSqlResult(res);
    q = "DROP TABLE IF EXISTS test_table1;";
    res = try conn.query(q);
    printSqlResult(res);
}

fn printSqlResult(res: pg.SqlResult) void{
    if (res.sqlError) |sqlError| {
        std.debug.print("sqlError: {s} {s}\n", .{sqlError.code, sqlError.message});
    } else {
        printRaws(res.sqlRaws);
    }
}

fn printRaws(res: ?pg.SqlRaws) void{
    if (res == null) {
        std.debug.print("No raws\n", .{});
        return;
    }

    var i: u32 = 0;
    var j: u32 = 0;
    std.debug.print("Columns:\n", .{});
    while (i < res.?.sqlColumns.len) {
        std.debug.print("{s} ({d}) ", .{res.?.sqlColumns[i].columnName, res.?.sqlColumns[i].dataType});
        i+=1;
    }

    std.debug.print("\n", .{});
    i = 0;
    while (i < res.?.raws.items.len) {
        j = 0;
        while (j < res.?.raws.items[i].fields.items.len) {
            std.debug.print("{s}       ", .{res.?.raws.items[i].fields.items[j]});
            j+=1;
        }
        std.debug.print("\n", .{});
        i+=1;
    }
}