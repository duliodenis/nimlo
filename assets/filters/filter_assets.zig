//! Bundled filter-list snapshots so content blocking works offline on the
//! first run; the update flow replaces them in the data directory
//! (docs/CONTENT_BLOCKING.md, Phase E). Versions and attribution: README.md
//! in this directory.

pub const easylist = @embedFile("easylist.txt");
pub const easyprivacy = @embedFile("easyprivacy.txt");
