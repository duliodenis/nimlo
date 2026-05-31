pub const Preferences = struct {
    homepage_url: []const u8,
    default_search_engine: []const u8,
    open_previous_session: bool,
    private_mode_default: bool,
    theme: []const u8,
    download_directory: []const u8,

    pub fn default() Preferences {
        return .{
            .homepage_url = "nimlo://start",
            .default_search_engine = "DuckDuckGo",
            .open_previous_session = false,
            .private_mode_default = false,
            .theme = "system",
            .download_directory = "",
        };
    }

    // TODO(storage): persist preferences locally. Telemetry is intentionally absent.
};
