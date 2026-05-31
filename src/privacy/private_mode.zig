pub const PrivateModeConfig = struct {
    enabled: bool,
    persist_history: bool,
    persist_session: bool,

    pub fn default() PrivateModeConfig {
        return .{
            .enabled = false,
            .persist_history = false,
            .persist_session = false,
        };
    }

    // TODO(privacy): enforce private window and permission behavior.
};
