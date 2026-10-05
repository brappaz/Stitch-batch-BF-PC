 * ====================================================================================
 * FIJI MACRO: Universal Batch Well Processing, Grid Stitching, and Mosaic Generation
 * Version 3.1 (2026-10-02)
 * ====================================================================================
 *
 * CHANGELOG:
 * v3.1 (2026-10-02)
 *   - Contrast is computed once per well and channel (histogram of all its tiles) and
 *     applied identically to every tile: no more brightness steps between tiles.
 *     Phase contrast tiles are first corrected for their background offset (median),
 *     which differs between fields in the raw IN Cell images.
 *   - Overlap "auto": the expected position of every tile is read from the .xdce
 *     metadata of each well (supports irregular field layouts, e.g. 10x custom fields).
 *   - Faster: files are indexed once (no folder rescans), registration and fusion of
 *     both channels are done in a single plugin call in the common case, and mosaics
 *     are built from thumbnails made during processing (merged images are not re-read).
 *   - Progress window with progress bar, wells done, elapsed and remaining time.
 * v3.0 (2026-10-02)
 *   - "Both (Brightfield + Phase Contrast)" processes the two channels in one run.
 *     Each well is registered once and the same tile positions are applied to both
 *     channels (identical geometry). Registration tries the 2-channel tiles first
 *     (both channels combined), then each channel alone, and keeps the first result
 *     that passes the tile-shift check.
 *   - Report gains a "Registration" column (which tiles gave the positions).
 * v2.2 (2026-10-02)
 *   - The mosaic is saved in a dedicated "Mosaics" folder of the input folder
 *     (Mosaics/Mosaic_<channel>.tif) instead of among the merged images.
 * v2.1 (2026-10-02)
 *   - Overlap "auto": estimated (X and Y separately) from the IN Cell .xdce metadata.
 *   - New "Min. overlap to attempt stitching": below it (e.g. 0% overlap) stitching is
 *     skipped and every well is tiled side by side.
 *   - Fix: summary line no longer crashes when the whole plate is tiled side by side.
 * v2.0 (2026-10-02)
 *   - Stitching validation: registered tile positions are checked against the expected
 *     grid; failed wells are tiled side by side (Log, Stitching_report.csv, "*" in mosaic).
 *   - Log reports the overlap measured on stitched wells.
 *   - All gridX*gridY fields are loaded (was fixed to 4); a missing field no longer
 *     shifts the other tiles in the grid.
 *   - Fix: invalid B&C threshold no longer crashes the macro (unsupported "?:" operator).
 *   - Temporary tiles are written to Merged_Images_<channel>/temp/ instead of the input folder.
 * v1.0 (2026-09-29)
 *   - Original version (archived in macros/archive/).
