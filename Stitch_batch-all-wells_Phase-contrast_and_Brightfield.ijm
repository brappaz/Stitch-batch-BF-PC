/*
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
 *
 * SUGGESTED USE:
 * This macro is designed for automated multi-well plate imaging where each well
 * is acquired as multiple fields of view (e.g., a 2x2 grid = 4 fields per well).
 *
 * 1. Place all your raw TIFF/PNG images in a single input folder.
 * 2. Ensure filenames contain the well ID and field number in a format matching:
 *    "WellName(fld X ...)" (e.g., "B - 03(fld 1 wv TL-Phase Contrast - Cy3).tif").
 * 3. Run the macro, select your channel (Both, Brightfield or Phase Contrast), and let
 *    it automatically stitch each well and build a final labeled plate mosaic.
 *    A "Stitching progress" window shows the progress and the remaining time.
 *
 * BOTH CHANNELS AT ONCE:
 * Brightfield and phase contrast are acquired at the same stage positions, so one
 * registration is valid for both. For every well the macro registers, in this order:
 *   1. 2-channel tiles (brightfield + phase contrast, averaged by the stitching plugin),
 *   2. brightfield tiles alone,
 *   3. phase contrast tiles alone,
 * and keeps the first one that passes the tile-shift check. Both channels are then
 * fused with these same positions. If none passes, both are tiled side by side.
 * Outputs: Merged_Images_Brightfield/, Merged_Images_Phase Contrast/ and Mosaics/.
 * A field is only used if it exists for every selected channel.
 *
 * CONTRAST & BACKGROUND CORRECTION INFO:
 * The macro dynamically adapts its image processing based on the channel:
 *
 * - "Brightfield" Mode (Pseudo-Flatfield Correction):
 *   Brightfield images often suffer from uneven illumination (vignetting). This
 *   mode creates a highly blurred copy (Gaussian Blur, sigma=50) of the original
 *   image to approximate the background illumination. It then DIVIDES the original
 *   image by this background (in 32-bit space) to perfectly flatten the field
 *   before applying contrast.
 *
 * - "Phase Contrast" Mode (Background Offset + Linear Stretch):
 *   Phase contrast images rely on specific optical halos. Dividing by a blurred
 *   background would destroy this information. Therefore, this mode skips the
 *   division. The IN Cell phase contrast fields have different background levels,
 *   so the median of each tile is subtracted (offset only, halos preserved)
 *   before the linear contrast stretch.
 *
 * - The contrast stretch is computed from the histogram of ALL tiles of a well
 *   (per channel) and the same range is applied to each tile, so the tiles of a
 *   well have consistent brightness.
 *
 * - "auto" B&C Saturation Threshold:
 *   By default, the threshold is set to "auto". This automatically applies a
 *   1.5% pixel saturation stretch for Brightfield (which needs a stronger push
 *   after division) and 1.0% for Phase Contrast. You can override this by typing
 *   a custom number in the dialog box (used for both channels).
 *
 * OVERLAP FROM METADATA ("auto"):
 * The field positions and pixel size are read from the IN Cell .xdce file of the
 * input folder. The expected position of every tile is taken from the metadata of
 * its well (works for any magnification and for irregular field layouts), and the
 * average overlap (X and Y) is reported. If it is below "Min. overlap to attempt
 * stitching" (e.g. fields acquired exactly edge to edge, 0% overlap), stitching is
 * skipped and every well is tiled side by side.
 * Type a number instead of "auto" to force a regular grid with a given overlap.
 *
 * STITCHING FALLBACK (small or no overlap):
 * When neighbouring tiles share little or no image content, the stitching plugin
 * rejects their correlation and silently drops the unconnected tile at (0,0), on top
 * of tile 1. This gives a black quadrant or a collapsed, rectangular image.
 * After registration, the macro therefore reads the registered TileConfiguration and
 * compares the offset between every pair of neighbouring tiles with the expected
 * offset. If any tile moved further than "Max tile shift", the registration
 * is rejected; when no registration passes, the tiles are placed side by side
 * (no overlap, no blending).
 * - Fallback wells are listed in the Log, in "Stitching_report.csv", and are
 *   marked with "*" in the mosaic.
 * - The Log also reports the overlap actually measured on the stitched wells.
 *
 * PERFORMANCE NOTES:
 * - Input files are indexed once; the folder is never rescanned per tile.
 * - In the common case a single plugin call registers AND fuses both channels.
 * - Stitching uses "Save computation time (but use more RAM)" to run 2-3x faster.
 * - Mosaics are assembled from thumbnails saved while processing each well.
 * - Java Garbage Collection (System.gc) is restricted to once per well.
 * ====================================================================================
 */

macro "Universal Batch Stitching and Mosaic" {
    macroVersion = "3.1";
    tStart = getTime();

    // --------------------------------------------------------- 1. Setup Dialog --
    Dialog.create("Batch Well Stitching & Mosaic v" + macroVersion);
    Dialog.addMessage("Grid Stitching Parameters:");
    Dialog.addDirectory("Input Folder", "");

    // Drop-down menu for channel selection
    channels = newArray("Both (Brightfield + Phase Contrast)", "Brightfield", "Phase Contrast");
    Dialog.addChoice("Target Channel", channels, channels[0]);
    Dialog.addMessage("  * 'Both' registers each well once and applies the same tile positions to both channels.");

    // B&C Saturation Input (Allows "auto" string or custom numbers)
    Dialog.addString("B&C Saturation Threshold (%)", "auto");
    Dialog.addMessage("  * 'auto' applies 1.5 for Brightfield and 1.0 for Phase Contrast.");

    // Overlap Input (Allows "auto" string or custom numbers)
    Dialog.addString("Overlap (%)", "auto");
    Dialog.addMessage("  * 'auto' reads the tile positions from the .xdce metadata (IN Cell) of the input\n     folder, falling back to a regular grid with 6% overlap if no metadata is found.");
    Dialog.addNumber("Grid Size X (columns)", 2);
    Dialog.addNumber("Grid Size Y (rows)", 2);

    // Grid assembly order options
    orders = newArray("Right & Down", "Left & Down", "Right & Up", "Left & Up", "Down & Right", "Down & Left", "Up & Right", "Up & Left");
    Dialog.addChoice("Grid Order", orders, "Right & Down");

    Dialog.addMessage("Stitching Fallback:");
    Dialog.addNumber("Min. overlap to attempt stitching (%)", 1);
    Dialog.addMessage("  * Below this overlap (e.g. ~0% from the metadata) stitching is skipped:\n     the tiles of every well are placed side by side.");
    Dialog.addNumber("Max tile shift vs. expected grid (% of tile size)", 10);
    Dialog.addMessage("  * If stitching moves a tile further than this, the well is not stitched:\n     its tiles are placed side by side instead.");

    Dialog.addMessage("Mosaic Parameters:");
    Dialog.addNumber("Mosaic Downsampling Scale (1 = full size)", 0.33);
    Dialog.show();

    // Fetch variables from dialog
    inputDir = Dialog.getString();
    channelChoice = Dialog.getChoice();
    threshInput = Dialog.getString();
    overlapInput = Dialog.getString();
    gridX = Dialog.getNumber();
    gridY = Dialog.getNumber();
    gridOrder = Dialog.getChoice();
    minOverlapPct = Dialog.getNumber();
    maxShiftPct = Dialog.getNumber();
    scale = Dialog.getNumber();

    inputDir = normalizeDir(inputDir);

    // Channels to process: name, short tag used for the temporary tiles, B&C threshold and output folder
    if (channelChoice == "Brightfield" || channelChoice == "Phase Contrast") chNames = newArray(channelChoice);
    else chNames = newArray("Brightfield", "Phase Contrast");
    nCh = chNames.length;

    // Parse the threshold input to assign dynamic values if "auto" is used
    customThresh = NaN;
    if (toLowerCase(threshInput) != "auto") {
        customThresh = parseFloat(threshInput);
        if (isNaN(customThresh)) print("Warning: Threshold not recognized. Using default values.");
    }

    chTags = newArray(nCh);
    bcThresh = newArray(nCh);
    outDirs = newArray(nCh);
    chLabel = "";
    for (c = 0; c < nCh; c++) {
        if (chNames[c] == "Brightfield") { chTags[c] = "bf"; bcThresh[c] = 1.5; }
        else { chTags[c] = "pc"; bcThresh[c] = 1.0; }
        if (!isNaN(customThresh)) bcThresh[c] = customThresh;

        // Create a dedicated output subfolder named dynamically using the channel
        outDirs[c] = inputDir + "Merged_Images_" + chNames[c] + "/";
        if (!File.exists(outDirs[c])) {
            File.makeDirectory(outDirs[c]);
        }
        if (c > 0) chLabel = chLabel + " + ";
        chLabel = chLabel + chNames[c];
    }
    print("Batch Well Stitching & Mosaic v" + macroVersion + " - " + chLabel + " - " + inputDir);

    // Registration candidates, tried in this order until one passes the tile-shift check.
    // With both channels: the 2-channel tiles (both channels averaged) first, then each channel alone.
    if (nCh == 2) regTags = newArray("mc", "bf", "pc");
    else regTags = newArray(chTags[0]);

    // Grid position (column, row) of every field number, based on the selected pattern
    nFields = gridX * gridY;
    colOf = newArray(nFields + 1);
    rowOf = newArray(nFields + 1);
    for (f = 1; f <= nFields; f++) {
        i = f - 1;
        x_idx = 0;
        y_idx = 0;
        if (gridOrder == "Right & Down") { x_idx = i % gridX; y_idx = floor(i / gridX); }
        else if (gridOrder == "Left & Down") { x_idx = (gridX - 1) - (i % gridX); y_idx = floor(i / gridX); }
        else if (gridOrder == "Right & Up") { x_idx = i % gridX; y_idx = (gridY - 1) - floor(i / gridX); }
        else if (gridOrder == "Left & Up") { x_idx = (gridX - 1) - (i % gridX); y_idx = (gridY - 1) - floor(i / gridX); }
        else if (gridOrder == "Down & Right") { x_idx = floor(i / gridY); y_idx = i % gridY; }
        else if (gridOrder == "Down & Left") { x_idx = (gridX - 1) - floor(i / gridY); y_idx = i % gridY; }
        else if (gridOrder == "Up & Right") { x_idx = floor(i / gridY); y_idx = (gridY - 1) - (i % gridY); }
        else if (gridOrder == "Up & Left") { x_idx = (gridX - 1) - floor(i / gridY); y_idx = (gridY - 1) - (i % gridY); }
        colOf[f] = x_idx;
        rowOf[f] = y_idx;
    }

    // ----------------------------- 2. Index Input Files & Find Unique Wells --
    // Every image is indexed once by "well|field|channel" (key-value list), so the tiles of a
    // well are found directly instead of rescanning the whole folder for each tile.
    list = getFileList(inputDir);
    Array.sort(list);
    List.clear();
    wellList = newArray(0);
    xdcePath = "";

    for (i = 0; i < list.length; i++) {
        fileName = list[i];
        low = toLowerCase(fileName);
        if (endsWith(low, ".xdce")) xdcePath = inputDir + fileName;

        // Well name = text preceding the first parenthesis, field = number following "fld "
        idx = indexOf(fileName, "(");
        p = indexOf(fileName, "fld ");
        if (idx > 0 && p > idx && (endsWith(low, ".tif") || endsWith(low, ".png"))) {
            q = indexOf(fileName, " ", p + 4);
            if (q > p + 4) {
                fieldStr = substring(fileName, p + 4, q);
                wellName = substring(fileName, 0, idx);
                for (c = 0; c < nCh; c++) {
                    if (indexOf(fileName, chNames[c]) > -1) {
                        if (List.get("W|" + wellName) == "") {
                            List.set("W|" + wellName, "1");
                            wellList = Array.concat(wellList, wellName);
                        }
                        List.set(wellName + "|" + fieldStr + "|" + c, fileName);
                    }
                }
            }
        }
    }
    wellCount = wellList.length;

    if (wellCount == 0) {
        showMessage("Error", "No '" + chLabel + "' images with valid well names 'Well(fld...)' found.");
        exit();
    }

    setBatchMode(true); // Hides image windows to speed up processing
    run("Conversions...", "scale"); // Ensures smooth scaling when converting 32-bit to 16-bit

    // ------------------------------------------------- 3. Resolve Tile Overlap --
    // "auto": tile positions and overlap from the field positions in the .xdce metadata
    overlapX = NaN;
    overlapY = NaN;
    xdceXml = "";       // Metadata kept in memory when used for the tile positions
    umPerPxX = NaN;
    umPerPxY = NaN;
    if (toLowerCase(overlapInput) == "auto") {
        if (xdcePath != "") {
            // Image size of the first tile (the metadata gives positions in µm)
            fn = "";
            for (f = 1; f <= nFields; f++) {
                if (fn == "") fn = List.get(wellList[0] + "|" + f + "|0");
            }
            if (fn != "") {
                open(inputDir + fn);
                firstW = getWidth();
                firstH = getHeight();
                close();
                xdceXml = File.openAsString(xdcePath);
                // Calibration is given for unbinned pixels
                pixW = parseFloat(xmlAttr(xdceXml, 0, "<ObjectiveCalibration", "pixel_width"));
                pixH = parseFloat(xmlAttr(xdceXml, 0, "<ObjectiveCalibration", "pixel_height"));
                binTxt = split(xmlAttr(xdceXml, 0, "<Binning", "value"), " xX");
                bin = 1;
                if (binTxt.length > 0 && !isNaN(parseFloat(binTxt[0]))) bin = parseFloat(binTxt[0]);
                umPerPxX = pixW * bin;
                umPerPxY = pixH * bin;
                ov = metaOverlap(xdceXml, wellList[0], nFields, colOf, rowOf, firstW * umPerPxX, firstH * umPerPxY);
                overlapX = ov[0];
                overlapY = ov[1];
                if (overlapX > 50 || overlapY > 50) {
                    print("Warning: the field positions in the metadata do not match the selected grid size/order.");
                    overlapX = NaN;
                }
            }
        }
        if (isNaN(overlapX) || isNaN(overlapY)) {
            print("Warning: Overlap could not be read from .xdce metadata. Using a regular grid with 6% overlap.");
            overlapX = 6;
            overlapY = 6;
            xdceXml = "";
        } else {
            print("Overlap from metadata (" + File.getName(xdcePath) + "): X " + d2s(overlapX, 1) + "%, Y " + d2s(overlapY, 1) + "% (average); tile positions read from the metadata of each well");
        }
    } else {
        overlapX = parseFloat(overlapInput);
        if (isNaN(overlapX)) {
            print("Warning: Overlap not recognized. Using 6%.");
            overlapX = 6;
        }
        overlapY = overlapX;
    }

    // With (almost) no overlap the tiles share no image content to register: skip stitching entirely
    doStitch = (minOf(overlapX, overlapY) >= minOverlapPct);
    if (!doStitch)
        print("Overlap below " + minOverlapPct + "%: stitching skipped, the tiles of every well are placed side by side.");

    // ---------------------------------------------------- 4. Process Each Well --

    // Temporary folder for the processed tiles of the current well (re-used for every well)
    tempDir = outDirs[0] + "temp/";
    if (!File.exists(tempDir)) {
        File.makeDirectory(tempDir);
    }
    // Mosaics of all channels are saved together in a dedicated folder; thumbnails are collected while processing
    mosaicDir = inputDir + "Mosaics/";
    if (!File.exists(mosaicDir)) {
        File.makeDirectory(mosaicDir);
    }
    thumbDir = mosaicDir + "temp_thumbnails/";
    if (!File.exists(thumbDir)) {
        File.makeDirectory(thumbDir);
    }

    // Progress window (not available when Fiji runs headless)
    headless = (getInfo("java.awt.headless") == "true");
    progressWin = "Stitching progress";
    if (!headless && !isOpen(progressWin)) run("Text Window...", "name=[" + progressWin + "] width=80 height=3 monospaced");

    nStitched = 0;
    nFallback = 0;
    regCounts = newArray(regTags.length);   // Number of wells stitched with each registration candidate
    fallbackIds = ",";          // Wells tiled side by side, e.g. ",O22,P08," (used to mark the mosaic)
    report = "# Batch Well Stitching & Mosaic v" + macroVersion + ", " + chLabel + ", overlap X " + d2s(overlapX, 1) + "% Y " + d2s(overlapY, 1) + "%\n";
    report = report + "Well,Tiles,Result,Registration,Max tile shift (px),Rejected registrations\n";
    overlapsX = newArray(0);    // Overlaps (%) measured between neighbouring tiles of stitched wells
    overlapsY = newArray(0);
    mergedW = newArray(wellCount);  // Size of the merged image of every well (0 = no image), used for the mosaic
    mergedH = newArray(wellCount);
    tLoop = getTime();

    for (w = 0; w < wellCount; w++) {
        currentWell = wellList[w];
        wellId = wellIdOf(currentWell);
        updateProgress(progressWin, headless, w, wellCount, tLoop, "Processing well " + currentWell);

        // A field is only used when it exists for every selected channel
        tileFound = newArray(nFields + 1);
        imageCount = 0;
        for (f = 1; f <= nFields; f++) {
            nFound = 0;
            for (c = 0; c < nCh; c++) {
                if (List.get(currentWell + "|" + f + "|" + c) != "") nFound++;
            }
            if (nFound == nCh) {
                tileFound[f] = 1;
                imageCount++;
            } else if (nFound > 0) {
                print("  Warning: " + currentWell + " field " + f + " is missing in one channel and is skipped");
            }
        }

        if (imageCount > 0) {
            imgW = 0;
            imgH = 0;
            baseNames = newArray(nCh);
            tileTypes = newArray(nCh);
            stackIds = newArray(nCh);
            sliceField = newArray(imageCount + 1);   // Field number of every slice of the well stacks

            // --- 5. CONDITIONAL IMAGE PROCESSING (B&C / BACKGROUND), one contrast per well and channel ---
            for (c = 0; c < nCh; c++) {
                baseNames[c] = "";
                for (f = 1; f <= nFields; f++) {
                    if (tileFound[f] == 1) {
                        fileName = List.get(currentWell + "|" + f + "|" + c);
                        open(inputDir + fileName);
                        origId = getImageID();
                        origTitle = getTitle();
                        if (imgW == 0) {
                            imgW = getWidth();
                            imgH = getHeight();
                        }

                        // Generate a clean base filename for the merged image from the first tile of the channel
                        if (baseNames[c] == "") {
                            dotIndex = lastIndexOf(fileName, ".");
                            if (dotIndex > 0) baseNames[c] = substring(fileName, 0, dotIndex);
                            else baseNames[c] = fileName;
                            // Strip the field identifier out of the final merged filename
                            baseNames[c] = replace(baseNames[c], "fld " + f + " ", "");
                        }

                        if (chNames[c] == "Brightfield") {
                            // Pseudo-Flatfield Correction for Brightfield
                            run("32-bit");
                            run("Duplicate...", "title=BlurredCopy");
                            blurId = getImageID();
                            run("Gaussian Blur...", "sigma=50");
                            imageCalculator("Divide create 32-bit", origTitle, "BlurredCopy");
                            resultId = getImageID();
                            selectImage(blurId);
                            close();
                            selectImage(origId);
                            close();
                            selectImage(resultId);
                        } else {
                            // Phase Contrast: remove the background level of the tile, which differs between fields
                            // (offset only: halos and contrast within the tile are preserved)
                            background = getValue("Median"); // On the raw image: fast histogram median for 8/16-bit
                            run("32-bit");
                            run("Subtract...", "value=" + background);
                        }
                        rename("tile" + f);
                    }
                }

                // Contrast from the histogram of ALL tiles of the well, applied identically to every tile
                if (imageCount > 1) run("Images to Stack", "name=well_stack title=tile use");
                stackIds[c] = getImageID();
                run("Enhance Contrast", "saturated=" + bcThresh[c] + " use");
                run("16-bit"); // Scales every tile of the stack with the same range
                tileTypes[c] = bitDepthName(bitDepth());

                // Save every tile under its field number (channel tag + field) for the stitching plugin
                nz = nSlices;
                for (z = 1; z <= nz; z++) {
                    selectImage(stackIds[c]);
                    setSlice(z);
                    if (nz > 1) f = parseInt(substring(getInfo("slice.label"), 4));
                    else f = parseInt(substring(getTitle(), 4));
                    sliceField[z] = f;
                    run("Duplicate...", "title=tmp");
                    saveAs("Tiff", tempDir + "tile_" + chTags[c] + "_" + f + ".tif");
                    close();
                }
                selectImage(stackIds[c]);
                rename("chstack" + c);
            }

            // 2-channel tiles (brightfield + phase contrast) for the combined registration and fusion
            mcOK = false;
            if (nCh == 2 && imageCount > 1 && doStitch) {
                if (tileTypes[0] == tileTypes[1]) {
                    mcOK = true;
                    for (z = 1; z <= imageCount; z++) {
                        selectImage(stackIds[0]);
                        setSlice(z);
                        run("Duplicate...", "title=mc1");
                        selectImage(stackIds[1]);
                        setSlice(z);
                        run("Duplicate...", "title=mc2");
                        run("Merge Channels...", "c1=mc1 c2=mc2 create");
                        saveAs("Tiff", tempDir + "tile_mc_" + sliceField[z] + ".tif");
                        close();
                    }
                }
            }
            close("*");

            // --- 6. Expected tile positions: metadata of the well (auto), otherwise regular grid + overlap ---
            expX = newArray(nFields + 1);
            expY = newArray(nFields + 1);
            useMeta = false;
            if (xdceXml != "") {
                useMeta = true;
                sx = newArray(nFields + 1);
                sy = newArray(nFields + 1);
                minSx = 1e30;
                maxSy = -1e30;
                for (f = 1; f <= nFields; f++) {
                    if (tileFound[f] == 1) {
                        pos = xdceStagePos(xdceXml, currentWell, f);
                        if (isNaN(pos[0]) || isNaN(pos[1])) useMeta = false;
                        sx[f] = pos[0];
                        sy[f] = pos[1];
                        minSx = minOf(minSx, pos[0]);
                        maxSy = maxOf(maxSy, pos[1]);
                    }
                }
                // Image x follows the stage x, image y is opposite to the stage y
                if (useMeta) {
                    for (f = 1; f <= nFields; f++) {
                        if (tileFound[f] == 1) {
                            expX[f] = (sx[f] - minSx) / umPerPxX;
                            expY[f] = (maxSy - sy[f]) / umPerPxY;
                        }
                    }
                }
            }
            if (!useMeta) {
                for (f = 1; f <= nFields; f++) {
                    expX[f] = colOf[f] * imgW * (1.0 - (overlapX / 100.0));
                    expY[f] = rowOf[f] * imgH * (1.0 - (overlapY / 100.0));
                }
            }

            stitched = false;
            fusedOpen = false;
            attempted = false;
            regTag = "";
            maxShift = 0;
            rejected = "";
            maxShiftPx = maxShiftPct / 100.0 * maxOf(imgW, imgH);
            nPairs = 0;

            if (imageCount > 1 && doStitch) {
                // --- 7. Register with each candidate until one passes the tile-shift check ---
                for (r = 0; r < regTags.length; r++) {
                    tag = regTags[r];
                    if (!stitched && (tag != "mc" || mcOK)) {
                        // The first candidate also fuses its tiles in the same call when they are the tiles
                        // to fuse (2-channel tiles, or the single channel): one plugin call per well in the common case
                        fuseNow = false;
                        if (!attempted && (tag == "mc" || nCh == 1)) fuseNow = true;
                        attempted = true;
                        if (fuseNow) fusionMethod = "[Linear Blending]";
                        else fusionMethod = "[Do not fuse images (only write TileConfiguration)]";

                        layout = "TileConfiguration_" + tag + ".txt";
                        regFile = tempDir + "TileConfiguration_" + tag + ".registered.txt";
                        writeLayout(tempDir + layout, "tile_" + tag + "_", tileFound, expX, expY, nFields);
                        if (File.exists(regFile)) ok = File.delete(regFile);
                        run("Grid/Collection stitching", "type=[Positions from file] " +
                            "order=[Defined by TileConfiguration] " +
                            "directory=[" + tempDir + "] " +
                            "layout_file=" + layout + " " +
                            "fusion_method=" + fusionMethod + " " +
                            "regression_threshold=0.30 " +
                            "max/avg_displacement_threshold=2.50 " +
                            "absolute_displacement_threshold=3.50 " +
                            "compute_overlap " +
                            "computation_parameters=[Save computation time (but use more RAM)] " +
                            "image_output=[Fuse and display]");

                        // --- 8. Validate the registration ---
                        // Read the registered tile positions written by the plugin
                        prefix = "tile_" + tag + "_";
                        regX = newArray(nFields + 1);
                        regY = newArray(nFields + 1);
                        regFound = newArray(nFields + 1);
                        if (File.exists(regFile)) {
                            lines = split(File.openAsString(regFile), "\n");
                            for (k = 0; k < lines.length; k++) {
                                if (startsWith(lines[k], prefix)) {
                                    f = parseInt(substring(lines[k], lengthOf(prefix), indexOf(lines[k], ".tif")));
                                    xy = split(substring(lines[k], lastIndexOf(lines[k], "(") + 1, lastIndexOf(lines[k], ")")), ",");
                                    regX[f] = parseFloat(xy[0]);
                                    regY[f] = parseFloat(xy[1]);
                                    regFound[f] = 1;
                                }
                            }
                        }

                        // Compare the registered offset of every pair of neighbouring tiles with the expected offset
                        shift = 0;
                        nPairs = 0;
                        regMissing = false;
                        pairOvX = newArray(0);
                        pairOvY = newArray(0);
                        for (a = 1; a <= nFields; a++) {
                            for (b = a + 1; b <= nFields; b++) {
                                if (tileFound[a] == 1 && tileFound[b] == 1 && abs(colOf[a] - colOf[b]) + abs(rowOf[a] - rowOf[b]) == 1) {
                                    nPairs++;
                                    if (regFound[a] == 1 && regFound[b] == 1) {
                                        dx = (regX[b] - regX[a]) - (expX[b] - expX[a]);
                                        dy = (regY[b] - regY[a]) - (expY[b] - expY[a]);
                                        shift = maxOf(shift, sqrt(dx * dx + dy * dy));
                                        if (rowOf[a] == rowOf[b]) pairOvX = Array.concat(pairOvX, 100 * (1 - abs(regX[b] - regX[a]) / imgW));
                                        else pairOvY = Array.concat(pairOvY, 100 * (1 - abs(regY[b] - regY[a]) / imgH));
                                    } else {
                                        regMissing = true;
                                    }
                                }
                            }
                        }

                        // No neighbouring tiles (e.g. only fields 1 and 4 of a 2x2 grid): nothing to validate
                        if (nPairs > 0 && !regMissing && shift <= maxShiftPx) {
                            stitched = true;
                            regTag = tag;
                            regCounts[r] = regCounts[r] + 1;
                            maxShift = shift;
                            posX = Array.copy(regX);
                            posY = Array.copy(regY);
                            overlapsX = Array.concat(overlapsX, pairOvX);
                            overlapsY = Array.concat(overlapsY, pairOvY);
                            if (fuseNow && nImages > 0) fusedOpen = true;
                        } else {
                            close("*"); // Discard the badly fused image
                            if (nPairs > 0) {
                                if (regMissing) shiftStr = "no result";
                                else shiftStr = d2s(shift, 0) + " px";
                                if (rejected != "") rejected = rejected + "; ";
                                rejected = rejected + tagName(tag) + " " + shiftStr;
                            }
                        }
                    }
                }
            }

            // Log the result of this well
            progressStr = "Well " + (w + 1) + "/" + wellCount + " " + currentWell + ": ";
            if (stitched) {
                nStitched++;
                result = "stitched";
                shiftStr = d2s(maxShift, 0);
                note = "";
                if (rejected != "") note = " - rejected: " + rejected;
                print(progressStr + "stitched with " + tagName(regTag) + " registration (max tile shift " + shiftStr + " px)" + note);
            } else if (!doStitch) {
                // Whole plate tiled side by side on purpose: no warning and no "*" mark in the mosaic
                nFallback++;
                shiftStr = "n/a";
                result = "tiled side by side (overlap below " + minOverlapPct + "%)";
                print(progressStr + "tiled side by side (overlap below " + minOverlapPct + "%)");
            } else {
                nFallback++;
                shiftStr = "n/a";
                fallbackIds = fallbackIds + wellId + ",";
                if (imageCount == 1) result = "single tile";
                else if (nPairs == 0) result = "no neighbouring tiles";
                else result = "no registration within " + d2s(maxShiftPx, 0) + " px";
                print(progressStr + "WARNING: not stitched (" + result + ") -> tiles placed side by side  [" + rejected + "]");
                result = "tiled side by side (" + result + ")";
            }
            report = report + wellId + "," + imageCount + "," + result + "," + tagName(regTag) + "," + shiftStr + "," + rejected + "\n";

            // --- 9. Build and save the merged image of every channel (+ mosaic thumbnail) ---
            if (stitched && mcOK) {
                // Both channels fused together (same positions), then split
                if (!fusedOpen) fuseTiles(tempDir, "mc", tileFound, posX, posY, nFields);
                fusedTitle = getTitle();
                run("Split Channels");
                for (c = 0; c < nCh; c++) {
                    selectWindow("C" + (c + 1) + "-" + fusedTitle);
                    mergedPath = outDirs[c] + baseNames[c] + "_merge.tif";
                    thumbPath = thumbDir + chTags[c] + "_" + w + ".tif";
                    size = saveMerged(mergedPath, thumbPath, scale);
                }
            } else {
                for (c = 0; c < nCh; c++) {
                    if (stitched) {
                        // Fuse this channel with the validated positions (same positions for every channel)
                        if (!fusedOpen) fuseTiles(tempDir, chTags[c], tileFound, posX, posY, nFields);
                    } else {
                        // Fallback: place the tiles side by side (no overlap, no stitching)
                        sideBySide(tempDir, "tile_" + chTags[c] + "_", tileFound, colOf, rowOf, nFields, gridX, gridY, imgW, imgH, tileTypes[c]);
                    }
                    mergedPath = outDirs[c] + baseNames[c] + "_merge.tif";
                    thumbPath = thumbDir + chTags[c] + "_" + w + ".tif";
                    size = saveMerged(mergedPath, thumbPath, scale);
                }
            }
            mergedW[w] = size[0];
            mergedH[w] = size[1];
            close("*");

            // Cleanup temporary files of this well
            tmpList = getFileList(tempDir);
            for (k = 0; k < tmpList.length; k++) ok = File.delete(tempDir + tmpList[k]);

            // Call Garbage Collector once per well to safely flush RAM without causing lag
            call("java.lang.System.gc");
        }
    }
    ok = File.delete(tempDir);
    List.clear();

    // Stitching summary
    for (c = 0; c < nCh; c++) File.saveString(report, outDirs[c] + "Stitching_report.csv");
    regSummary = "";
    for (r = 0; r < regTags.length; r++) {
        if (r > 0) regSummary = regSummary + ", ";
        regSummary = regSummary + tagName(regTags[r]) + ": " + regCounts[r];
    }
    print("=== Stitching summary: " + nStitched + " wells stitched (" + regSummary + "), " + nFallback + " wells tiled side by side ===");
    if (lengthOf(fallbackIds) > 1) print("Stitching failed, tiled side by side: " + substring(fallbackIds, 1, lengthOf(fallbackIds) - 1));
    if (overlapsX.length > 0)
        print("Measured overlap X: median " + d2s(medianOf(overlapsX), 1) + "% (10-90th percentile " + d2s(percentileOf(overlapsX, 10), 1) + " to " + d2s(percentileOf(overlapsX, 90), 1) + "%)");
    if (overlapsY.length > 0)
        print("Measured overlap Y: median " + d2s(medianOf(overlapsY), 1) + "% (10-90th percentile " + d2s(percentileOf(overlapsY, 10), 1) + " to " + d2s(percentileOf(overlapsY, 90), 1) + "%)");
    print("Overlap used: X " + d2s(overlapX, 1) + "%, Y " + d2s(overlapY, 1) + "%. Report saved as Stitching_report.csv in each Merged_Images folder.");

    // --------------------------------------------------- 10. Mosaic Generation --
    for (c = 0; c < nCh; c++) {
        updateProgress(progressWin, headless, wellCount, wellCount, tLoop, "Building mosaic: " + chNames[c]);
        buildMosaic(thumbDir, chTags[c], wellList, mergedW, mergedH, scale, fallbackIds, mosaicDir + "Mosaic_" + chNames[c] + ".tif");
    }
    thumbList = getFileList(thumbDir);
    for (k = 0; k < thumbList.length; k++) ok = File.delete(thumbDir + thumbList[k]);
    ok = File.delete(thumbDir);

    setBatchMode(false);
    showProgress(1);
    showStatus("");
    totalTime = (getTime() - tStart) / 1000;
    print("Total time: " + formatTime(totalTime) + " (" + d2s(totalTime / wellCount, 1) + " s per well)");
    if (!headless && isOpen(progressWin)) print("[" + progressWin + "]", "\\Close");

    showMessage("Done", "Batch stitching & Mosaic generation completed in " + formatTime(totalTime) + "!\n" +
                nStitched + " wells stitched, " + nFallback + " wells tiled side by side (marked * in the mosaic, see Log).\n" +
                "Merged files are in the 'Merged_Images_...' folders of:\n" + inputDir + "\nMosaics are saved in: " + mosaicDir);
}

// ====================================================================================
// Helper Functions
// ====================================================================================

// Updates the progress window, the ImageJ progress bar and status line
function updateProgress(win, headless, done, total, t0, label) {
    frac = done / total;
    nBar = 40;
    nFill = floor(frac * nBar);
    bar = "";
    for (i = 0; i < nBar; i++) {
        if (i < nFill) bar = bar + "#";
        else bar = bar + "-";
    }
    elapsed = (getTime() - t0) / 1000;
    remaining = "";
    if (done > 0 && done < total) remaining = "   remaining ~" + formatTime(elapsed / done * (total - done));
    line1 = "[" + bar + "] " + round(100 * frac) + "%   " + done + "/" + total + " wells";
    line2 = label + "   -   elapsed " + formatTime(elapsed) + remaining;
    if (!headless && isOpen(win)) print("[" + win + "]", "\\Update:" + line1 + "\n" + line2);
    showProgress(frac);
    showStatus(done + "/" + total + " wells" + remaining);
}

// Formats a duration in seconds as "1h 02m 05s", "12m 05s" or "45s"
function formatTime(s) {
    s = round(s);
    h = floor(s / 3600);
    m = floor((s % 3600) / 60);
    sec = s % 60;
    if (h > 0) return "" + h + "h " + IJ.pad(m, 2) + "m " + IJ.pad(sec, 2) + "s";
    if (m > 0) return "" + m + "m " + IJ.pad(sec, 2) + "s";
    return "" + sec + "s";
}

// Fuses the tiles 'tile_<tag>_<field>.tif' at the given positions (no registration); the fused image is left open
function fuseTiles(dir, tag, tileFound, xs, ys, nFields) {
    layout = "TileConfiguration_fuse_" + tag + ".txt";
    writeLayout(dir + layout, "tile_" + tag + "_", tileFound, xs, ys, nFields);
    run("Grid/Collection stitching", "type=[Positions from file] " +
        "order=[Defined by TileConfiguration] " +
        "directory=[" + dir + "] " +
        "layout_file=" + layout + " " +
        "fusion_method=[Linear Blending] " +
        "regression_threshold=0.30 " +
        "max/avg_displacement_threshold=2.50 " +
        "absolute_displacement_threshold=3.50 " +
        "computation_parameters=[Save computation time (but use more RAM)] " +
        "image_output=[Fuse and display]");
}

// Saves the active image, then saves a downscaled copy for the mosaic and closes it. Returns its full size.
function saveMerged(path, thumbPath, scale) {
    saveAs("Tiff", path);
    w = getWidth();
    h = getHeight();
    if (scale != 1)
        run("Size...", "width=" + maxOf(1, round(w * scale)) + " height=" + maxOf(1, round(h * scale)) + " average interpolation=Bilinear");
    saveAs("Tiff", thumbPath);
    close();
    return newArray(w, h);
}

// Builds the labelled plate mosaic of one channel from the thumbnails saved while processing and saves it
// to 'outPath'. Wells listed in 'fallbackIds' (e.g. ",O22,P08,") are labelled with "*".
function buildMosaic(thumbDir, tag, wellList, mergedW, mergedH, scale, fallbackIds, outPath) {
    labelFraction = 0.125;

    // Plate position of every well with a merged image
    n = wellList.length;
    ids  = newArray(n);
    rows = newArray(n);
    cols = newArray(n);
    widths  = newArray(0);
    heights = newArray(0);
    minRow = 1e9; maxRow = -1; minCol = 1e9; maxCol = -1;
    for (i = 0; i < n; i++) {
        ids[i] = wellIdOf(wellList[i]);
        letters = "";
        digits = "";
        for (k = 0; k < lengthOf(ids[i]); k++) {
            ch = substring(ids[i], k, k + 1);
            if (matches(ch, "[A-Za-z]")) letters = letters + ch;
            else if (matches(ch, "[0-9]")) digits = digits + ch;
        }
        rows[i] = -1;
        if (mergedW[i] > 0 && lengthOf(letters) > 0 && lengthOf(letters) <= 2 && lengthOf(digits) > 0) {
            rows[i] = rowIndex(letters);
            cols[i] = parseInt(digits);
            if (rows[i] > 0 && !isNaN(cols[i])) {
                minRow = minOf(minRow, rows[i]); maxRow = maxOf(maxRow, rows[i]);
                minCol = minOf(minCol, cols[i]); maxCol = maxOf(maxCol, cols[i]);
                widths  = Array.concat(widths,  mergedW[i]);
                heights = Array.concat(heights, mergedH[i]);
            } else {
                rows[i] = -1;
            }
        }
    }
    if (widths.length == 0) {
        print("No merged well images to make a mosaic.");
        return;
    }
    nRows = maxRow - minRow + 1;
    nCols = maxCol - minCol + 1;

    // Square crop of the median well size, downsampled by 'scale'
    side = round(minOf(medianOf(widths), medianOf(heights)));
    tileSize = maxOf(1, round(side * scale));
    fontSize = maxOf(8, round(tileSize * labelFraction));

    mosaicId = 0;
    bd = 0;
    placed = newArray(n);
    for (i = 0; i < n; i++) {
        if (rows[i] > 0) {
            open(thumbDir + tag + "_" + i + ".tif");
            if (mosaicId == 0) {
                // Create the blank canvas with the type of the merged images
                bd = bitDepth();
                thumbId = getImageID();
                newImage("Mosaic", bitDepthName(bd) + " black", nCols * tileSize, nRows * tileSize, 1);
                mosaicId = getImageID();
                selectImage(thumbId);
            }
            if (bitDepth() == bd) {
                // Center crop to ensure uniform squares
                tw = getWidth();
                th = getHeight();
                makeRectangle(maxOf(0, floor((tw - tileSize) / 2)), maxOf(0, floor((th - tileSize) / 2)), minOf(tileSize, tw), minOf(tileSize, th));
                run("Crop");
                if (getWidth() != tileSize || getHeight() != tileSize)
                    run("Canvas Size...", "width=" + tileSize + " height=" + tileSize + " position=Center zero");
                run("Select All");
                run("Copy");
                close();

                // Paste into the correct grid coordinate on the mosaic
                selectImage(mosaicId);
                makeRectangle((cols[i] - minCol) * tileSize, (rows[i] - minRow) * tileSize, tileSize, tileSize);
                run("Paste");
                run("Select None");
                placed[i] = 1;
            } else {
                close(); // Skip if bit depth is mismatched
            }
        }
    }

    // --- 11. Draw Labels & Save ---
    selectImage(mosaicId);
    run("Select None");
    if (bd == 16) fullMax = 65535;
    else if (bd == 32) fullMax = 1;
    else fullMax = 255;
    if (bd != 24) setMinAndMax(0, fullMax);

    setFont("SansSerif", fontSize, "bold antialiased");
    if (bd == 24) setColor(255, 255, 255);
    else setColor(fullMax);
    pad = maxOf(2, round(tileSize * 0.03));

    // Burn well IDs (e.g., "A01") onto the top left corner of each tile; "*" marks wells tiled side by side
    for (i = 0; i < n; i++) {
        if (placed[i] == 1) {
            label = ids[i];
            if (indexOf(fallbackIds, "," + ids[i] + ",") > -1) label = label + "*";
            drawString(label, (cols[i] - minCol) * tileSize + pad, (rows[i] - minRow) * tileSize + pad + fontSize);
        }
    }
    if (bd != 24) setMinAndMax(0, fullMax);

    saveAs("Tiff", outPath);
    close();
    print("Saved Final Mosaic: " + outPath);
}

// Writes a TileConfiguration file listing the found tiles ('prefix' + field + ".tif") at positions (xs, ys)
function writeLayout(path, prefix, tileFound, xs, ys, nFields) {
    s = "# Define the number of dimensions we are working on\ndim = 2\n\n# Define the image coordinates\n";
    for (f = 1; f <= nFields; f++) {
        if (tileFound[f] == 1) s = s + prefix + f + ".tif; ; (" + xs[f] + ", " + ys[f] + ")\n";
    }
    File.saveString(s, path);
}

// Places the found tiles ('prefix' + field + ".tif") side by side on the grid, without overlap or blending.
// The resulting image is left open and active.
function sideBySide(dir, prefix, tileFound, colOf, rowOf, nFields, gridX, gridY, imgW, imgH, tileType) {
    newImage("SideBySide", tileType + " black", gridX * imgW, gridY * imgH, 1);
    sideId = getImageID();
    for (f = 1; f <= nFields; f++) {
        if (tileFound[f] == 1) {
            open(dir + prefix + f + ".tif");
            run("Select All");
            run("Copy");
            close();
            selectImage(sideId);
            makeRectangle(colOf[f] * imgW, rowOf[f] * imgH, imgW, imgH);
            run("Paste");
        }
    }
    run("Select None");
}

// Readable name of a registration candidate
function tagName(tag) {
    if (tag == "mc") return "2-channel";
    if (tag == "bf") return "Brightfield";
    if (tag == "pc") return "Phase Contrast";
    return "-";
}

// Normalizes file paths to ensure compatibility across Windows/Mac/Linux
function normalizeDir(d) {
    d = replace(d, "\\\\", "/");
    if (!endsWith(d, "/"))
        d = d + "/";
    return d;
}

// Converts letters (A, B, C...) to numerical row indices (1, 2, 3...)
function rowIndex(letters) {
    letters = toUpperCase(letters);
    v = 0;
    for (i = 0; i < lengthOf(letters); i++) {
        p = indexOf("ABCDEFGHIJKLMNOPQRSTUVWXYZ", substring(letters, i, i + 1));
        if (p < 0) return -1;
        v = v * 26 + p + 1;
    }
    return v;
}

// Converts a raw well name (e.g. "B - 03") to the well ID used in the mosaic labels (e.g. "B03")
function wellIdOf(raw) {
    letters = "";
    digits = "";
    for (k = 0; k < lengthOf(raw); k++) {
        ch = substring(raw, k, k + 1);
        if (matches(ch, "[A-Za-z]")) letters = letters + ch;
        else if (matches(ch, "[0-9]")) digits = digits + ch;
    }
    return toUpperCase(letters) + digits;
}

// Stage position (µm, OffsetFromWellCenter) of a field of a well in an IN Cell .xdce file; NaN if absent
function xdceStagePos(xml, well, f) {
    k = indexOf(xml, "filename=\"" + well + "(fld " + f + " ");
    if (k < 0) return newArray(NaN, NaN);
    return newArray(parseFloat(xmlAttr(xml, k, "<OffsetFromWellCenter", "x")), parseFloat(xmlAttr(xml, k, "<OffsetFromWellCenter", "y")));
}

// Average overlap (%) between neighbouring fields of a well from the .xdce field positions.
// fieldW/fieldH = size of a field in µm. Returns newArray(overlapX, overlapY), NaN if unknown.
function metaOverlap(xml, well, nFields, colOf, rowOf, fieldW, fieldH) {
    fx = newArray(nFields + 1);
    fy = newArray(nFields + 1);
    found = newArray(nFields + 1);
    for (f = 1; f <= nFields; f++) {
        pos = xdceStagePos(xml, well, f);
        fx[f] = pos[0];
        fy[f] = pos[1];
        if (!isNaN(fx[f]) && !isNaN(fy[f])) found[f] = 1;
    }

    // Average overlap over all pairs of neighbouring fields in the grid
    sumX = 0; nX = 0; sumY = 0; nY = 0;
    for (a = 1; a <= nFields; a++) {
        for (b = a + 1; b <= nFields; b++) {
            if (found[a] == 1 && found[b] == 1 && abs(colOf[a] - colOf[b]) + abs(rowOf[a] - rowOf[b]) == 1) {
                if (rowOf[a] == rowOf[b]) { sumX = sumX + 100 * (1 - abs(fx[b] - fx[a]) / fieldW); nX++; }
                else { sumY = sumY + 100 * (1 - abs(fy[b] - fy[a]) / fieldH); nY++; }
            }
        }
    }
    ovX = NaN;
    ovY = NaN;
    if (nX > 0) ovX = sumX / nX;
    if (nY > 0) ovY = sumY / nY;
    // A single-row or single-column grid only has neighbours along one axis
    if (isNaN(ovX)) ovX = ovY;
    if (isNaN(ovY)) ovY = ovX;
    return newArray(ovX, ovY);
}

// Returns the value of attribute 'attr' of the first 'tag' found in 'xml' after position 'from' ("" if absent)
function xmlAttr(xml, from, tag, attr) {
    k = indexOf(xml, tag, from);
    if (k < 0) return "";
    seg = substring(xml, k, indexOf(xml, ">", k));
    a = indexOf(seg, " " + attr + "=\"");
    if (a < 0) return "";
    a = a + lengthOf(attr) + 3;
    return substring(seg, a, indexOf(seg, "\"", a));
}

// Returns the image type string used by newImage() for a given bit depth
function bitDepthName(bits) {
    if (bits == 8) return "8-bit";
    if (bits == 24) return "RGB";
    if (bits == 32) return "32-bit";
    return "16-bit";
}

// Calculates the median value of an array without modifying the original array
function medianOf(a) {
    b = Array.copy(a);
    Array.sort(b);
    m = b.length;
    if (m == 0) return NaN;
    if (m % 2 == 1) return b[floor(m / 2)];
    return (b[floor(m / 2) - 1] + b[floor(m / 2)]) / 2;
}

// Returns the p-th percentile (nearest rank) of an array without modifying the original array
function percentileOf(a, p) {
    b = Array.copy(a);
    Array.sort(b);
    if (b.length == 0) return NaN;
    return b[round(p / 100 * (b.length - 1))];
}
