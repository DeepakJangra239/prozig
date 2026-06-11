/// SQLite C bindings — single cImport for the entire project.
pub const c = @cImport({
    @cInclude("sqlite3.h");
});
