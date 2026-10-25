// Completed metadata-reader detail totals. Normal instrumentation deliberately
// exposes zeroes here; operational range/read/error counters remain mandatory.
pub fn countersValid(summary: anytype, detailed: bool) bool {
    if (detailed) return summary.loader_metadata_logical_reads > summary.loader_metadata_window_fills and
        summary.loader_metadata_window_hits > 0 and summary.loader_metadata_window_fills > 0 and
        summary.loader_metadata_window_fill_bytes > 0 and
        summary.loader_file_range_read_bytes >= summary.loader_metadata_window_fill_bytes;
    return summary.loader_metadata_logical_reads == 0 and summary.loader_metadata_logical_bytes == 0 and
        summary.loader_metadata_window_hits == 0 and summary.loader_metadata_window_fills == 0 and
        summary.loader_metadata_window_fill_bytes == 0 and summary.loader_metadata_direct_reads == 0 and
        summary.loader_metadata_direct_bytes == 0;
}
