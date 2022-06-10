const std = @import("std");
const pg = @import("pg");
const ArrayList = std.ArrayList;

pub fn main() !void {
    var conn = pg.Conn{ .host = "127.0.0.1", .port = 5433, .user = "postgres", .password = "postgres", .database = "postgres" };
    try conn.connect(conn.host, conn.port);
    defer conn.deinit();

    var q: []const u8 = "";
    // var q: []const u8 = "CREATE TABLE IF NOT EXISTS test_table1(id integer, name TEXT);";
    // var res = try conn.query(q);
    // printSqlResult(res);
    // q = "insert into test_table1(id, name) values(1, 'name1')";
    // res = try conn.query(q);
    // printSqlResult(res);
    // q = "insert into test_table1(id, name) values(2, 'name2')";
    // res = try conn.query(q);
    // printSqlResult(res);
    q = "select * from test_table1";
    var res = try conn.query(q);
    printSqlResult(res);
    // var q = "select * fom test_table1";
    // var res = try conn.query(q);
    // printSqlResult(res);

    // q = "select id, name from1 test_table1 where id = $1";
    // var array: [1]i32 = .{23};
    // try conn.execute("q1", q, &array);

    // q = "COPY test_table1 FROM STDIN DELIMITER ','";
    // var inputData: ArrayList(u8) = ArrayList(u8).init(std.heap.c_allocator);
    // try inputData.appendSlice("15,name11\n12,name12");
    // try conn.copy(q, inputData.items);
    // var q = "COPY (SELECT id FROM test_table1 WHERE id=1) TO '/Users/pav.popov/projects/pets/zig/pg/demo.txt'  DELIMITER ' ';";
    // var q = "COPY test_table1 FROM '/Users/pav.popov/projects/pets/zig/pg/postgres-data.csv' DELIMITER ',' CSV HEADER;";
    // try conn.copy(q, inputData.items);
    // q = "COPY (SELECT id FROM test_table1 WHERE id=1) TO STDOUT DELIMITER ',';";
    // try conn.copy(q, undefined);

    // q = "DROP TABLE IF EXISTS test_table1;";
    // res = try conn.query(q);
    // printSqlResult(res);

    // try conn.asyncQ();
}

fn printSqlResult(res: pg.SqlResult) void {
    if (res.sqlError) |sqlError| {
        std.debug.print("sqlError: {s} {s}\n", .{ sqlError.code.items, sqlError.message.items });
    } else {
        printRaws(res.sqlRaws);
    }
}

fn printRaws(res: ?pg.SqlRaws) void {
    if (res == null) {
        std.debug.print("No raws\n", .{});
        return;
    }

    var i: u32 = 0;
    var j: u32 = 0;
    std.debug.print("Columns:\n", .{});
    while (i < res.?.sqlColumns.len) {
        std.debug.print("{s} ({d}) ", .{ res.?.sqlColumns[i].columnName.items, res.?.sqlColumns[i].dataType });
        i += 1;
    }

    std.debug.print("\n", .{});
    i = 0;
    while (i < res.?.raws.items.len) {
        j = 0;
        while (j < res.?.raws.items[i].fields.items.len) {
            std.debug.print("{s}       ", .{res.?.raws.items[i].fields.items[j]});
            j += 1;
        }
        std.debug.print("\n", .{});
        i += 1;
    }
}
