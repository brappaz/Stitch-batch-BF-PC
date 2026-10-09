/*
 * ====================================================================================
 * FIJI MACRO: Crop Brightfield and Phase Contrast images to the DHM field of view
 * Version 1.1 (2026-10-09)
 * ====================================================================================
 *
 * CHANGELOG:
 * v1.1 (2026-10-09)
 *   - BF single fields from the background-corrected folder (Processed_BG_Corrected_Brightfield),
 *     or raw BF images corrected by the macro with the same method ("BF single fields").
 * v1.0 (2026-10-09)
 *   - Original version.
 *
 * PURPOSE:
 * For every well, finds the area imaged by the DHM (stitched DHM image) in the IN Cell
 * brightfield (BF) and phase contrast (PC) images of the same well, and saves BF and PC
 * crops covering exactly the DHM field of view.
 *
 * SUGGESTED USE:
 * 1. DHM folder: one stitched DHM image per well, named "<Well>_<anything>.tif"
 *    (e.g. "B03_00001_00001.tif"). Pixels equal to 0 are empty areas (stitching corners).
 * 2. BF + PC folder: IN Cell single fields, e.g. "B - 03(fld 5 wv TL-Brightfield - ...).tif".
 *    The field matched with the DHM ("Field matched with DHM", default fld 5) is tried first.
 *    BF single fields ("BF single fields"):
 *    - Background-corrected images (default): from "Processed_BG_Corrected_Brightfield" (or the
 *      folder chosen), e.g. "B - 03(fld 5 wv TL-Brightfield - ...)_bg-corrected.tif". A missing
 *      corrected image is replaced by the raw image corrected by the macro (noted in the report).
 *    - Raw images, background-corrected by this macro: same correction as these images (division
 *      by a Gaussian blur, sigma 50 px; contrast stretch with 0.35% saturated pixels; 16-bit).
 *    - Raw images: no correction.
 *    PC single fields are always the raw images of the BF + PC folder. Stitched BF images are
 *    used as they are (already corrected by the stitching macro).
 * 3. Stitched folders (used when the DHM area is not entirely inside fld 5): fields 1-4
 *    stitched per well, e.g. the "Merged_Images_Brightfield" and "Merged_Images_Phase
 *    Contrast" folders written by Stitch_batch-all-wells_Phase-contrast_and_Brightfield.ijm
 *    (default when the stitched folder fields are left empty).
 * 4. Run the macro, choose the folders and keep the defaults.
 *
 * HOW IT WORKS:
 * - Registration: the DHM image is scaled to the BF/PC pixel size, rotated, band-pass
 *   filtered (cell scale) and located in the registration channel (PC by default) by
 *   masked normalised cross-correlation (FFT, 4x down-sampled). Empty DHM corners and the
 *   image borders are masked, so partial overlaps are measured correctly.
 * - Scale and rotation ("auto"): the pixel size written in DHM files can be inaccurate
 *   (0.300 µm in the file vs 0.275 µm measured, 20x, 2026-09 plates). Scale and rotation
 *   are measured on the first wells whose DHM area lies inside fld 5 (median of 3 wells)
 *   and applied to the whole plate. Type numbers in the dialog to skip this step
 *   (rotation in ImageJ convention: positive = clockwise).
 * - Pass 1: the DHM image is searched in the whole fld 5 image. If its whole area lies
 *   inside fld 5, BF and PC are cropped from fld 5; otherwise the DHM image is searched in
 *   the whole stitched fld 1-4 image and BF and PC are cropped from the stitched images.
 *   Only confident matches (clear correlation peak) are cropped in pass 1.
 * - Plate model: the plate is not placed identically on both instruments, so the DHM
 *   position varies smoothly over the plate. A plane (position vs well row and column) is
 *   fitted on the confident wells (2026-09 plate: 33 px median deviation).
 * - Pass 2: the other wells, and confident wells far from the plate model, are searched
 *   only within +-150 px (~50 µm) of the predicted position. Without a match there (empty
 *   or blurred DHM image, cells moved too much), the predicted position is used.
 * - BF and PC are acquired at the same position (measured offset < 0.5 px): the
 *   registration of one channel is used for both.
 * - Output pixel grid "DHM": the crops are rotated and resampled (bilinear) onto the DHM
 *   pixel grid. They have the size and calibration of the DHM image and overlay it pixel
 *   to pixel. "BF/PC": plain crop at the native BF/PC resolution (no resampling; the
 *   small rotation is ignored).
 *
 * OUTPUTS (output folder, default <BF + PC folder>/Cropped_to_DHM/):
 *   Brightfield/<DHM name>_BF.tif        BF crop (16-bit)
 *   Phase Contrast/<DHM name>_PC.tif     PC crop (16-bit)
 *   QC/<DHM name>_QC.jpg                 DHM (magenta) over the PC crop (green), 1/3 size
 *   Crop_report.csv                      per well: source, how the position was found,
 *                                        score, peak ratio, position, plate-model deviation
 *
 * MATCH SCORE AND ACCURACY:
 * - Score = normalised cross-correlation of the band-passed images (1 = identical).
 *   BF/PC is acquired hours after the DHM and cells move, so correct matches score
 *   0.15-0.50 and scores below 0.10 are not reliable. "Peak ratio" = best score / best
 *   score elsewhere; close to 1 = ambiguous.
 * - The position is reproducible within ~5 px (1.5 µm). Single cells may have moved by
 *   more between the two acquisitions: check the QC overlays.
 * ====================================================================================
 */

var DS = 4;            // Down-sampling factor of the registration (BF/PC pixels)
var SIG1 = 1;          // Band-pass: small Gaussian sigma (down-sampled px)
var SIG2 = 8;          // Band-pass: large Gaussian sigma (down-sampled px) = 32 BF/PC px, ~10 µm
var CLIP_IQR = 5;      // Registration images are clipped to median +- CLIP_IQR x interquartile range
var CONF_SCORE = 0.15; // Pass 1: a match is confident if score >= CONF_SCORE ...
var CONF_RATIO = 1.5;  // ... and score >= CONF_RATIO x best score elsewhere (peak ratio)
var MAXDEV = 150;      // Pass 2: search radius around the plate-model position (BF/PC px, ~50 um)
var AMBIGUOUS = 1.3;   // Without plate model: peak ratio below which a match is flagged "ambiguous"
var BF_SIGMA = 50;     // BF flat-field correction: Gaussian sigma (px) of the background ...
var BF_SAT = 0.35;     // ... and saturated pixels (%) of the contrast stretch (= Processed_BG_Corrected_Brightfield images)
var BFMODE = 0;        // BF single fields: 0 = background-corrected folder, 1 = raw corrected by the macro, 2 = raw
var BFPCDIR = "";      // BF + PC single-field folder
var BFCORRDIR = "";    // Background-corrected BF single-field folder
var LOGFILE = "";      // Optional copy of the Log (used for headless tests)

macro "Crop BF and PC to DHM field of view" {
    macroVersion = "1.1";
    tStart = getTime();
    headless = (getInfo("java.awt.headless") == "true");
    um = getInfo("micrometer.abbreviation");    // "µm" (non-ASCII characters are avoided in strings: file encoding)
    chNames = newArray("Brightfield", "Phase Contrast");   // Also the keywords in the IN Cell file names
    chTags = newArray("BF", "PC");
    gridChoices = newArray("DHM (same size and pixels as the DHM image)", "BF/PC (crop only, no resampling)");
    bfChoices = newArray("Background-corrected images (folder above)", "Raw images, background-corrected by this macro", "Raw images (no correction)");
    bfLabels = newArray("background-corrected folder", "raw + background correction by the macro", "raw");

    // --------------------------------------------------------- 1. Parameters --
    // Without argument: dialog. With argument (headless tests): "key=value;key=value..."
    arg = getArgument();
    wellFilter = "";
    if (arg == "") {
        Dialog.create("Crop BF & PC to DHM v" + macroVersion);
        Dialog.addMessage("Folders:");
        Dialog.addDirectory("DHM stitched images", call("ij.Prefs.get", "crop2dhm.dhm", ""), 60);
        Dialog.addDirectory("BF + PC single fields", call("ij.Prefs.get", "crop2dhm.bfpc", ""), 60);
        Dialog.addDirectory("Corrected BF single fields", "", 60);
        Dialog.addDirectory("Stitched BF (fld 1-4)", "", 60);
        Dialog.addDirectory("Stitched PC (fld 1-4)", "", 60);
        Dialog.addDirectory("Output folder", "", 60);
        Dialog.addMessage("  * Empty corrected BF folder = 'Processed_BG_Corrected_Brightfield' of the BF + PC folder.\n" +
                          "  * Empty stitched folders = 'Merged_Images_Brightfield' and 'Merged_Images_Phase Contrast' of the BF + PC folder.\n" +
                          "  * Empty output folder = 'Cropped_to_DHM' in the BF + PC folder.");
        Dialog.addChoice("BF single fields", bfChoices, bfChoices[0]);
        Dialog.addMessage("  * Background correction = division by a Gaussian blur (sigma " + BF_SIGMA + " px), contrast stretch (" + BF_SAT + "% saturated).\n" +
                          "  * A missing corrected image is replaced by the raw image corrected by the macro. PC: raw single fields.");
        Dialog.addMessage("Matching:");
        Dialog.addNumber("Field matched with DHM (fld)", 5);
        Dialog.addChoice("Registration channel", chNames, chNames[1]);
        Dialog.addString("DHM pixel size (" + um + ")", "auto");
        Dialog.addString("DHM rotation (deg)", "auto");
        Dialog.addMessage("  * 'auto' measures the DHM scale and rotation on the first wells. Type numbers to use fixed values.");
        Dialog.addNumber("Min. match score", 0.10);
        Dialog.addChoice("Output pixel grid", gridChoices, gridChoices[0]);
        Dialog.addCheckbox("Save QC overlays (DHM magenta, PC green)", true);
        Dialog.show();
        dhmDir = Dialog.getString();
        bfpcDir = Dialog.getString();
        bfCorrDir = Dialog.getString();
        stBF = Dialog.getString();
        stPC = Dialog.getString();
        outDir = Dialog.getString();
        bfChoice = Dialog.getChoice();
        fld = Dialog.getNumber();
        regName = Dialog.getChoice();
        pxStr = Dialog.getString();
        rotStr = Dialog.getString();
        minScore = Dialog.getNumber();
        gridChoice = Dialog.getChoice();
        saveQC = Dialog.getCheckbox();
        call("ij.Prefs.set", "crop2dhm.dhm", dhmDir);
        call("ij.Prefs.set", "crop2dhm.bfpc", bfpcDir);
    } else {
        List.clear();
        parts = split(arg, ";");
        for (i = 0; i < parts.length; i++) {
            k = indexOf(parts[i], "=");
            if (k > 0) List.set(substring(parts[i], 0, k), substring(parts[i], k + 1));
        }
        dhmDir = List.get("dhm");
        bfpcDir = List.get("bfpc");
        bfCorrDir = List.get("bfcorr");
        stBF = List.get("bfst");
        stPC = List.get("pcst");
        outDir = List.get("out");
        bfChoice = bfChoices[0];
        if (List.get("bfmode") == "macro") bfChoice = bfChoices[1];
        if (List.get("bfmode") == "raw") bfChoice = bfChoices[2];
        fld = 5;
        if (List.get("fld") != "") fld = parseInt(List.get("fld"));
        regName = chNames[1];
        if (List.get("chan") == "BF") regName = chNames[0];
        pxStr = "auto";
        if (List.get("px") != "") pxStr = List.get("px");
        rotStr = "auto";
        if (List.get("rot") != "") rotStr = List.get("rot");
        minScore = 0.10;
        if (List.get("minscore") != "") minScore = parseFloat(List.get("minscore"));
        gridChoice = gridChoices[0];
        if (List.get("grid") == "native") gridChoice = gridChoices[1];
        saveQC = (List.get("qc") != "0");
        wellFilter = List.get("wells");      // e.g. "B03,K15" (subset of wells)
        LOGFILE = List.get("log");
        List.clear();
        headless = true;                     // Scripted run: no progress window, no final message
    }

    if (dhmDir == "" || bfpcDir == "") exit("Please choose the DHM folder and the BF + PC folder.");
    dhmDir = normalizeDir(dhmDir);
    bfpcDir = normalizeDir(bfpcDir);
    BFPCDIR = bfpcDir;
    for (i = 0; i < bfChoices.length; i++) if (bfChoice == bfChoices[i]) BFMODE = i;
    if (bfCorrDir == "") bfCorrDir = bfpcDir + "Processed_BG_Corrected_Brightfield/";
    bfCorrDir = normalizeDir(bfCorrDir);
    BFCORRDIR = bfCorrDir;
    if (BFMODE == 0 && !File.isDirectory(bfCorrDir)) exit("Background-corrected BF folder not found:\n" + bfCorrDir +
        "\n\nChoose it in the dialog, or choose 'BF single fields' = '" + bfChoices[1] + "'.");
    if (stBF == "") stBF = bfpcDir + "Merged_Images_Brightfield/";
    if (stPC == "") stPC = bfpcDir + "Merged_Images_Phase Contrast/";
    stBF = normalizeDir(stBF);
    stPC = normalizeDir(stPC);
    stDirs = newArray(stBF, stPC);
    if (outDir == "") outDir = bfpcDir + "Cropped_to_DHM/";
    outDir = normalizeDir(outDir);
    regC = 1;
    if (regName == chNames[0]) regC = 0;
    signed = (regC == 1);       // PC: signed band-pass (cells bright in both); BF: magnitude (contrast sign varies with focus)
    dhmGrid = (gridChoice == gridChoices[0]);
    fldStr = "" + fld;

    // ---------------------------------------------- 2. Index the input files --
    // DHM images: "<Row><Col>_....tif" -> IN Cell well name "<Row> - <Col 2 digits>"
    list = getFileList(dhmDir);
    dhmFiles = newArray(0);
    dhmIds = newArray(0);
    dhmWells = newArray(0);
    for (i = 0; i < list.length; i++) {
        n = list[i];
        if (!matches(n, "(?i)^[A-Z]{1,2}[0-9]{1,2}_.*\\.tiff?$")) continue;
        id = toUpperCase(substring(n, 0, indexOf(n, "_")));
        if (wellFilter != "" && indexOf("," + wellFilter + ",", "," + id + ",") < 0) continue;
        letters = "";
        k = 0;
        while (matches(substring(id, k, k + 1), "[A-Z]")) { letters = letters + substring(id, k, k + 1); k++; }
        dhmFiles = Array.concat(dhmFiles, n);
        dhmIds = Array.concat(dhmIds, id);
        dhmWells = Array.concat(dhmWells, letters + " - " + IJ.pad(parseInt(substring(id, k)), 2));
    }
    nW = dhmFiles.length;
    if (nW == 0) exit("No DHM images named '<Well>_....tif' (e.g. B03_00001_00001.tif) in:\n" + dhmDir);

    // Single fields: key "<well>|<fld>|<channel>"; stitched images: key "<well>|st|<channel>"
    List.clear();
    list = getFileList(bfpcDir);
    for (i = 0; i < list.length; i++) {
        n = list[i];
        p = indexOf(n, "(fld ");
        if (p < 1 || !matches(n, "(?i).*\\.(tiff?|png)$")) continue;
        f = substring(n, p + 5, indexOf(n, " ", p + 5));
        for (c = 0; c < 2; c++) if (indexOf(n, chNames[c]) >= 0) List.set(substring(n, 0, p) + "|" + f + "|" + c, n);
    }
    // Background-corrected BF single fields: key "<well>|<fld>|bc"
    nCorr = 0;
    if (BFMODE == 0) {
        list = getFileList(bfCorrDir);
        for (i = 0; i < list.length; i++) {
            n = list[i];
            p = indexOf(n, "(fld ");
            if (p < 1 || indexOf(n, chNames[0]) < 0 || !matches(n, "(?i).*\\.(tiff?|png)$")) continue;
            List.set(substring(n, 0, p) + "|" + substring(n, p + 5, indexOf(n, " ", p + 5)) + "|bc", n);
            nCorr++;
        }
    }
    for (c = 0; c < 2; c++) {
        if (!File.isDirectory(stDirs[c])) continue;
        list = getFileList(stDirs[c]);
        for (i = 0; i < list.length; i++) {
            n = list[i];
            p = indexOf(n, "(");
            if (p > 0 && indexOf(n, "_merge") > 0 && indexOf(n, chNames[c]) >= 0) List.set(substring(n, 0, p) + "|st|" + c, n);
        }
        // Wells the stitching macro could not stitch (tiles placed side by side)
        rep = stDirs[c] + "Stitching_report.csv";
        if (c == regC && File.exists(rep)) {
            lines = split(File.openAsString(rep), "\n");
            for (i = 0; i < lines.length; i++) {
                cols = split(lines[i], ",");
                if (cols.length > 2 && !startsWith(cols[0], "#") && cols[0] != "Well") List.set("rep|" + cols[0], cols[2]);
            }
        }
    }

    // Output folders
    File.makeDirectory(outDir);
    for (c = 0; c < 2; c++) File.makeDirectory(outDir + chNames[c] + "/");
    if (saveQC) File.makeDirectory(outDir + "QC/");
    if (!File.isDirectory(outDir)) exit("Cannot create the output folder:\n" + outDir);

    setBatchMode(true);
    logMsg("=== Crop BF & PC to DHM v" + macroVersion + " ===");
    logMsg("DHM: " + dhmDir);
    logMsg("BF + PC: " + bfpcDir + "  (fld " + fldStr + ", registration on " + regName + ")");
    if (BFMODE == 0) logMsg("BF single fields: " + bfCorrDir + "  (" + nCorr + " background-corrected images)");
    else logMsg("BF single fields: " + bfChoice);
    logMsg("" + nW + " DHM images");

    // --------------------------------------------- 3. Pixel sizes, scale and rotation --
    // s = size of one DHM pixel in BF/PC pixels; theta = rotation (°) applied to the DHM image
    dhmPxFile = NaN;
    dhmUnit = "";
    tlPx = NaN;
    for (w = 0; w < nW && (isNaN(dhmPxFile) || isNaN(tlPx)); w++) {
        f1 = List.get("" + dhmWells[w] + "|" + fldStr + "|" + regC);
        if (f1 == "") continue;
        open(dhmDir + dhmFiles[w]);
        getPixelSize(dhmUnit, pw, ph);
        dhmPxFile = toMicron(dhmUnit, pw);
        close();
        open(bfpcDir + f1);
        getPixelSize(u, pw, ph);
        tlPx = toMicron(u, pw);
        close();
    }
    if (isNaN(tlPx)) exit("No '" + regName + "' fld " + fldStr + " image found for the DHM wells in:\n" + bfpcDir);
    if (isNaN(dhmPxFile)) dhmPxFile = tlPx;
    sNom = dhmPxFile / tlPx;

    sFix = NaN;
    thFix = NaN;
    if (toLowerCase(pxStr) != "auto") sFix = parseFloat(pxStr) / tlPx;
    if (toLowerCase(rotStr) != "auto") thFix = parseFloat(rotStr);
    if (isNaN(sFix) && toLowerCase(pxStr) != "auto") exit("Invalid DHM pixel size: " + pxStr);
    if (isNaN(thFix) && toLowerCase(rotStr) != "auto") exit("Invalid DHM rotation: " + rotStr);
    s = sFix;
    theta = thFix;

    if (isNaN(sFix) || isNaN(thFix)) {
        logMsg("Measuring DHM scale and rotation (DHM file: " + d2s(dhmPxFile, 4) + " " + um + "/px, BF/PC: " + d2s(tlPx, 4) + " " + um + "/px)...");
        calMin = minScore + 0.05;
        calS = newArray(0);
        calT = newArray(0);
        tried = 0;
        for (w = 0; w < nW && calS.length < 3 && tried < 12; w++) {
            fp = fieldPaths("" + dhmWells[w], fldStr);
            if (fp[regC] == "") continue;
            tried++;
            showStatus("Measuring DHM scale and rotation: " + dhmIds[w]);
            openDHM(dhmDir + dhmFiles[w]);
            dW = getWidth();
            dH = getHeight();
            openSource("" + fp[regC], "src", signed, needsFlatField("" + fp[regC], regC));
            sW = getWidth();
            sH = getHeight();
            if (calS.length == 0) r = calibrate(sNom, sFix, thFix, NaN, NaN, signed);
            else r = calibrate(sNom, sFix, thFix, medianOf(calS), medianOf(calT), signed);
            ctr = centreOf(r[3], r[4], round(dW * r[1] / DS), round(dH * r[1] / DS), sW, sH);
            fits = insideImage(ctr[0], ctr[1], dW, dH, r[1], r[2], sW, sH, 2);
            msg = "  " + dhmIds[w] + ": score " + d2s(r[0], 3) + ", DHM pixel " + d2s(r[1] * tlPx, 4) + " " + um + ", rotation " + d2s(r[2], 2) + " deg";
            if (r[0] >= calMin && fits) {
                calS = Array.concat(calS, r[1]);
                calT = Array.concat(calT, r[2]);
                logMsg(msg);
            } else {
                logMsg(msg + " -> not used (" + calReason(r[0], calMin, fits, fldStr) + ")");
            }
            closeWork();
            call("java.lang.System.gc");
        }
        if (calS.length == 0) {
            setBatchMode(false);
            exit("Could not measure the DHM scale and rotation (no DHM area found inside fld " + fldStr + " of the first wells).\n" +
                 "Type the DHM pixel size (" + um + ") and rotation (deg) in the dialog.");
        }
        if (isNaN(sFix)) s = medianOf(calS);
        if (isNaN(thFix)) theta = medianOf(calT);
    }
    dhmPx = s * tlPx;
    logMsg("DHM pixel size " + d2s(dhmPx, 4) + " " + um + " (file: " + d2s(dhmPxFile, 4) + " " + um + "), rotation " + d2s(theta, 2) + " deg, scale DHM -> BF/PC " + d2s(s, 4));

    // ------------------------------------------------- 4. Pass 1: search each well --
    // The DHM image is searched in the whole fld 5 image, then (if its area is not entirely inside)
    // in the whole stitched image. Confident matches are cropped now, the other wells in pass 2.
    progressWin = "Crop progress";
    if (!headless && !isOpen(progressWin)) run("Text Window...", "name=[" + progressWin + "] width=80 height=3 monospaced");
    wStat = newArray(nW);      // 1 = cropped, 2 = for pass 2, 3 = not found
    wSrc = newArray(nW);       // "field", "stitched", "partial" or "" (not found)
    wHow = newArray(nW);       // How the position was found: "search", "plate model window", "plate model"
    wX = newArray(nW);         // DHM centre in the source image (full-resolution pixels)
    wY = newArray(nW);
    wScore = newArray(nW);
    wSecond = newArray(nW);
    wFrac = newArray(nW);
    wInFld = newArray(nW);     // DHM area in fld 5 (pass 1): inside / partly outside / not found
    wNote = newArray(nW);
    wCol = newArray(nW);
    wRow = newArray(nW);
    fldW = 0;                  // Size of the fld 5 images
    fldH = 0;
    haveSt = false;            // At least one stitched image
    tLoop = getTime();

    for (w = 0; w < nW; w++) {
        id = dhmIds[w];
        updateProgress(progressWin, headless, w, nW, tLoop, "Pass 1: well " + id);
        wRow[w] = rowIndex("" + dhmWells[w]);
        wCol[w] = parseInt(substring(id, lengthOf(id) - 2));
        fFiles = fieldPaths("" + dhmWells[w], fldStr);
        stFiles = wellFiles("" + dhmWells[w], "st");
        if (stFiles[regC] != "") haveSt = true;
        wNote[w] = "";
        wInFld[w] = "-";
        wSrc[w] = "";
        wHow[w] = "search";
        r1 = newArray(-1, 0, 0, 0, -1, 0, 0);
        r2 = newArray(-1, 0, 0, 0, -1, 0, 0);
        res = r1;

        openDHM(dhmDir + dhmFiles[w]);
        dW = getWidth();
        dH = getHeight();
        features("dhm", s / DS, theta, signed, "tpl", "tplMask");

        // 1) Field matched with the DHM (fld 5): used if the whole DHM area is inside
        if (fFiles[regC] != "") {
            r1 = registerIn("" + fFiles[regC], "fld", signed, needsFlatField("" + fFiles[regC], regC), 0.5, 0, 0, 0);
            fldW = r1[5];
            fldH = r1[6];
            fits1 = insideImage(r1[1], r1[2], dW, dH, s, theta, fldW, fldH, 2);
            wInFld[w] = "not found";
            if (r1[0] >= minScore && fits1) wInFld[w] = "inside";
            if (r1[0] >= minScore && !fits1) wInFld[w] = "partly outside";
            if (wInFld[w] == "inside") {
                wSrc[w] = "field";
                res = r1;
            }
        } else wNote[w] = "no fld " + fldStr + " image";
        // 2) Otherwise: stitched fld 1-4 image
        if (wSrc[w] == "" && stFiles[regC] != "") {
            closeIfOpen("fld");
            r2 = registerIn("" + stDirs[regC] + stFiles[regC], "st", signed, false, 0.8, 0, 0, 0);
            if (r2[0] >= minScore) {
                wSrc[w] = "stitched";
                res = r2;
            }
        }
        // 3) Last resort: the part of the DHM area that is inside fld 5
        if (wSrc[w] == "" && r1[0] >= minScore) {
            wSrc[w] = "partial";
            res = r1;
        }
        wScore[w] = maxOf(r1[0], r2[0]);
        if (wSrc[w] != "") {
            wScore[w] = res[0];
            wX[w] = res[1];
            wY[w] = res[2];
            wFrac[w] = res[3];
            wSecond[w] = res[4];
        }

        // Confident: clear peak (score and peak ratio). Partial crops are always re-checked in pass 2.
        if ((wSrc[w] == "field" || wSrc[w] == "stitched") && wScore[w] >= CONF_SCORE && wScore[w] >= CONF_RATIO * wSecond[w]) {
            missing = cropWell("" + wSrc[w], wX[w], wY[w], fFiles, stFiles, stDirs, outDir, "" + dhmFiles[w], regC, s, theta, dhmGrid, saveQC);
            wNote[w] = appendNote(wNote[w], missing);
            wStat[w] = 1;
            logMsg("Well " + (w + 1) + "/" + nW + " " + id + ": " + sourceLabel("" + wSrc[w], fldStr) + " (score " + d2s(wScore[w], 3) +
                   ", peak ratio " + d2s(wScore[w] / maxOf(wSecond[w], 0.001), 2) + ")" + noteSuffix(wNote[w]));
        } else {
            wStat[w] = 2;
            logMsg("Well " + (w + 1) + "/" + nW + " " + id + ": no clear match (best score " + d2s(wScore[w], 3) + "), searched again in pass 2");
        }
        closeWork();
        call("java.lang.System.gc");
    }

    // ------------------------------------------------------------ 5. Plate model --
    // The DHM position varies smoothly over the plate (the plate is not placed identically on both
    // instruments): X and Y = a + b * column + c * row, fitted on the confident wells. Positions are
    // expressed in the frame of the stitched images; fld 5 positions are shifted by the position of
    // fld 5 in the stitched image, measured by registering fld 5 in the stitched image of a few wells.
    model = false;
    offX = 0;
    offY = 0;
    nDefer = 0;
    if (haveSt) {
        updateProgress(progressWin, headless, nW, nW, tLoop, "Measuring the position of fld " + fldStr + " in the stitched images");
        off = fieldOffset(dhmWells, fldStr, regC, stDirs, signed);
        if (off[0] >= 0.5) {
            offX = off[1];
            offY = off[2];
            logMsg("fld " + fldStr + " in the stitched images: top-left at (" + d2s(offX, 0) + ", " + d2s(offY, 0) + ") px (score " + d2s(off[0], 2) + ")");
        } else {
            haveSt = false;
            logMsg("WARNING: fld " + fldStr + " not found in the stitched images (score " + d2s(off[0], 2) + "): plate model from fld " + fldStr + " wells only");
        }
    }
    mX = newArray(nW);         // Positions in the frame of the plate model
    mY = newArray(nW);
    use = newArray(nW);        // Wells used to fit the model
    for (w = 0; w < nW; w++) {
        mX[w] = wX[w];
        mY[w] = wY[w];
        if (wSrc[w] != "stitched") {
            mX[w] = wX[w] + offX;
            mY[w] = wY[w] + offY;
        }
        use[w] = (wStat[w] == 1);
        if (!haveSt && wSrc[w] == "stitched") use[w] = false;
    }
    cX = fitPlane(wCol, wRow, mX, use);
    cY = fitPlane(wCol, wRow, mY, use);
    if (!isNaN(cX[0]) && !isNaN(cY[0])) {
        // Robust fit: fit again without the wells far from the first fit
        dev = newArray(0);
        for (w = 0; w < nW; w++) if (use[w]) dev = Array.concat(dev, planeDev(cX, cY, wCol[w], wRow[w], mX[w], mY[w]));
        lim = maxOf(3 * medianOf(dev), 30);
        for (w = 0; w < nW; w++) if (use[w] && planeDev(cX, cY, wCol[w], wRow[w], mX[w], mY[w]) > lim) use[w] = false;
        cX = fitPlane(wCol, wRow, mX, use);
        cY = fitPlane(wCol, wRow, mY, use);
    }
    if (!isNaN(cX[0]) && !isNaN(cY[0])) {
        model = true;
        dev = newArray(0);
        for (w = 0; w < nW; w++) if (use[w]) dev = Array.concat(dev, planeDev(cX, cY, wCol[w], wRow[w], mX[w], mY[w]));
        Array.getStatistics(dev, dmin, dmax);
        logMsg("Plate model from " + dev.length + " wells: deviation median " + d2s(medianOf(dev), 0) + " px, max " + d2s(dmax, 0) + " px");
        // Confident wells far from the model are searched again
        for (w = 0; w < nW; w++) {
            if (wStat[w] == 1 && planeDev(cX, cY, wCol[w], wRow[w], mX[w], mY[w]) > MAXDEV) {
                wStat[w] = 2;
                logMsg("  " + dhmIds[w] + ": " + d2s(planeDev(cX, cY, wCol[w], wRow[w], mX[w], mY[w]), 0) + " px from the plate model, searched again in pass 2");
            }
        }
    } else logMsg("WARNING: not enough confident wells for a plate model: pass 2 keeps the pass 1 results");
    for (w = 0; w < nW; w++) if (wStat[w] == 2) nDefer++;

    // ------------------------------------------------- 6. Pass 2: remaining wells --
    // Search within +-MAXDEV pixels of the position predicted by the plate model. Without a match
    // above "Min. match score" in this window, the predicted position is used.
    tPass2 = getTime();
    k = 0;
    for (w = 0; w < nW; w++) {
        if (wStat[w] != 2) continue;
        id = dhmIds[w];
        updateProgress(progressWin, headless, k, nDefer, tPass2, "Pass 2: well " + id);
        k++;
        fFiles = fieldPaths("" + dhmWells[w], fldStr);
        stFiles = wellFiles("" + dhmWells[w], "st");
        openDHM(dhmDir + dhmFiles[w]);
        dW = getWidth();
        dH = getHeight();
        if (model) {
            features("dhm", s / DS, theta, signed, "tpl", "tplMask");
            pX = cX[0] + cX[1] * wCol[w] + cX[2] * wRow[w];
            pY = cY[0] + cY[1] * wCol[w] + cY[2] * wRow[w];
            useSt = (haveSt && stFiles[regC] != "");
            src = "";
            // fld 5 if the predicted DHM area is inside it (or if there is no stitched image)
            if (fFiles[regC] != "" && (!useSt || insideImage(pX - offX, pY - offY, dW, dH, s, theta, fldW, fldH, 0))) {
                rr = registerIn("" + fFiles[regC], "fld", signed, needsFlatField("" + fFiles[regC], regC), 0.5, pX - offX, pY - offY, MAXDEV);
                src = "field";
                how = "plate model window";
                if (rr[0] < minScore) {
                    rr[1] = pX - offX;
                    rr[2] = pY - offY;
                    how = "plate model";
                }
                if (!insideImage(rr[1], rr[2], dW, dH, s, theta, rr[5], rr[6], 2)) {
                    src = "partial";
                    if (useSt) src = "";
                }
            }
            if (src == "" && useSt) {
                closeIfOpen("fld");
                rr = registerIn("" + stDirs[regC] + stFiles[regC], "st", signed, false, 0.8, pX, pY, MAXDEV);
                src = "stitched";
                how = "plate model window";
                if (rr[0] < minScore) {
                    rr[1] = pX;
                    rr[2] = pY;
                    how = "plate model";
                }
            }
            wSrc[w] = src;
            if (src != "") {
                wHow[w] = how;
                wScore[w] = rr[0];
                wX[w] = rr[1];
                wY[w] = rr[2];
                wFrac[w] = rr[3];
                wSecond[w] = rr[4];
                if (how == "plate model") wNote[w] = appendNote(wNote[w], "no match near the predicted position");
            }
        } else if (wSrc[w] != "" && wScore[w] < AMBIGUOUS * wSecond[w]) wNote[w] = appendNote(wNote[w], "ambiguous match - check QC");
        if (wSrc[w] == "partial") wNote[w] = appendNote(wNote[w], "crop partly empty");
        if (wSrc[w] != "") {
            missing = cropWell("" + wSrc[w], wX[w], wY[w], fFiles, stFiles, stDirs, outDir, "" + dhmFiles[w], regC, s, theta, dhmGrid, saveQC);
            wNote[w] = appendNote(wNote[w], missing);
            wStat[w] = 1;
            logMsg("Pass 2 " + id + ": " + sourceLabel("" + wSrc[w], fldStr) + ", " + wHow[w] + " (score " + d2s(wScore[w], 3) + ")" + noteSuffix(wNote[w]));
        } else {
            wStat[w] = 3;
            logMsg("Pass 2 " + id + ": WARNING no match (best score " + d2s(wScore[w], 3) + ")");
        }
        closeWork();
        call("java.lang.System.gc");
    }

    // ----------------------------------------------------------- 7. Report --
    report = "# Crop BF & PC to DHM v" + macroVersion + ", registration on " + regName + ", DHM pixel " + d2s(dhmPx, 4) +
             " um (file " + d2s(dhmPxFile, 4) + " um), BF/PC pixel " + d2s(tlPx, 4) + " um, rotation " + d2s(theta, 2) +
             " deg, output grid " + gridName(dhmGrid) + ", BF single fields " + bfLabels[BFMODE] + "\n";
    report = report + "Well,DHM image,Source,Position from,Score,Peak ratio,Overlap (%),Centre X (px),Centre Y (px)," +
             "Deviation from plate model (px),DHM area in fld " + fldStr + " (pass 1),Note\n";
    nField = 0;
    nStitched = 0;
    nPartial = 0;
    nModel = 0;
    notFound = "";
    for (w = 0; w < nW; w++) {
        if (wSrc[w] == "field") nField++;
        if (wSrc[w] == "stitched") nStitched++;
        if (wSrc[w] == "partial") nPartial++;
        if (wSrc[w] != "" && wHow[w] != "search") nModel++;
        if (wSrc[w] == "") notFound = notFound + " " + dhmIds[w];
        ratio = "";
        if (wSecond[w] > 0) ratio = d2s(wScore[w] / wSecond[w], 2);
        devStr = "";
        if (model && wSrc[w] != "") {
            if (wSrc[w] == "stitched") dv = planeDev(cX, cY, wCol[w], wRow[w], wX[w], wY[w]);
            else dv = planeDev(cX, cY, wCol[w], wRow[w], wX[w] + offX, wY[w] + offY);
            devStr = d2s(dv, 0);
        }
        if (wSrc[w] == "") {
            report = report + dhmIds[w] + "," + dhmFiles[w] + ",none,," + d2s(wScore[w], 3) + ",,,,,," + wInFld[w] + "," + replace(wNote[w], ",", ";") + "\n";
        } else {
            report = report + dhmIds[w] + "," + dhmFiles[w] + "," + sourceLabel("" + wSrc[w], fldStr) + "," + wHow[w] + "," + d2s(wScore[w], 3) + "," +
                     ratio + "," + d2s(100 * wFrac[w], 1) + "," + d2s(wX[w], 1) + "," + d2s(wY[w], 1) + "," + devStr + "," + wInFld[w] + "," +
                     replace(wNote[w], ",", ";") + "\n";
        }
    }
    File.saveString(report, outDir + "Crop_report.csv");
    updateProgress(progressWin, headless, nW, nW, tLoop, "Done");
    totalTime = (getTime() - tStart) / 1000;
    logMsg("");
    logMsg("Cropped from fld " + fldStr + ": " + nField + ", from stitched fld 1-4: " + nStitched + ", partial: " + nPartial +
           " (" + nModel + " positioned with the plate model), not found: " + (nW - nField - nStitched - nPartial));
    if (notFound != "") logMsg("Not cropped:" + notFound);
    logMsg("Output: " + outDir);
    logMsg("Total time: " + formatTime(totalTime) + " (" + d2s(totalTime / nW, 1) + " s per well)");
    setBatchMode(false);
    showProgress(1);
    showStatus("");
    if (!headless && isOpen(progressWin)) print("[" + progressWin + "]", "\\Close");
    if (!headless) showMessage("Done", "Cropping completed in " + formatTime(totalTime) + ".\n" +
                               nField + " wells cropped from fld " + fldStr + ", " + nStitched + " from the stitched fld 1-4 images, " +
                               nPartial + " partial (" + nModel + " positioned with the plate model).\nSee the Log and Crop_report.csv in:\n" + outDir);
}

// ====================================================================================
// Helper Functions
// ====================================================================================

// Opens a DHM image as "dhm" (32-bit) and prepares its filled copy and valid-pixel mask (see prepFill)
function openDHM(path) {
    open(path);
    rename("dhm");
    run("Select None");
    if (bitDepth() != 32) run("32-bit");
    prepFill("dhm");
    selectImage("dhm");
}

// Opens a BF/PC image as 'title' and computes its registration features "feat" and "featMask"
function openSource(path, title, signed, flat) {
    open(path);
    if (flat) flatField();
    rename(title);
    run("Select None");
    prepFill(title);
    features(title, 1 / DS, 0, signed, "feat", "featMask");
    close(title + "_f");
    close(title + "_m");
    selectImage(title);
}

// Creates "<src>_m" (1 = valid pixel, 0 = empty area where src == 0) and "<src>_f" (src with the
// empty areas filled by the mean of the valid pixels, so that filtering does not create edges there).
// Isolated zeros (e.g. pixels clipped by a contrast stretch) are not empty areas and stay valid.
function prepFill(src) {
    selectImage(src);
    run("Select None");
    run("Duplicate...", "title=[" + src + "_m]");
    run("32-bit");
    run("Abs");
    run("Multiply...", "value=1e9");
    run("Max...", "value=1");
    run("Maximum...", "radius=3");
    getRawStatistics(nPix, validFrac);
    selectImage(src);
    getRawStatistics(nPix, meanAll);
    meanValid = 0;
    if (validFrac > 0) meanValid = meanAll / validFrac;
    selectImage(src + "_m");
    run("Duplicate...", "title=[" + src + "_f]");
    run("Multiply...", "value=" + (-meanValid));
    run("Add...", "value=" + meanValid);
    imageCalculator("Add", src + "_f", src);
    // Outliers (DHM unwrapping errors, debris, saturated pixels) would dominate the correlation:
    // values are clipped to median +- CLIP_IQR x interquartile range
    selectImage(src + "_f");
    getRawStatistics(nPix, mean, vmin, vmax);
    if (vmax > vmin) {
        nBins = 4096;
        getHistogram(values, counts, nBins, vmin, vmax);
        q = newArray(0.25, 0.5, 0.75, 2);    // (2 = end marker: no short-circuit evaluation in macros)
        qv = newArray(3);
        cum = 0;
        j = 0;
        for (b = 0; b < nBins; b++) {
            cum += counts[b];
            while (cum >= q[j] * nPix) {
                qv[j] = vmin + (b + 0.5) * (vmax - vmin) / nBins;
                j++;
            }
        }
        iqr = qv[2] - qv[0];
        if (iqr > 0) {
            run("Max...", "value=" + (qv[1] + CLIP_IQR * iqr));
            run("Min...", "value=" + (qv[1] - CLIP_IQR * iqr));
        }
    }
}

// Registration features of image 'src' (needs prepFill): scaled by f, rotated by th (°), band-passed.
// outT = features (0 outside the valid area), outM = mask (1 = valid, eroded away from empty areas)
function features(src, f, th, signed, outT, outM) {
    selectImage(src + "_f");
    w = round(getWidth() * f);
    h = round(getHeight() * f);
    run("Scale...", "x=- y=- width=" + w + " height=" + h + " interpolation=Bilinear average create title=[" + outT + "]");
    run("Gaussian Blur...", "sigma=" + SIG1);
    run("Duplicate...", "title=bp_low");
    run("Gaussian Blur...", "sigma=" + SIG2);
    imageCalculator("Subtract", outT, "bp_low");
    close("bp_low");
    if (!signed) {
        selectImage(outT);
        run("Abs");
    }
    selectImage(src + "_m");
    run("Scale...", "x=- y=- width=" + w + " height=" + h + " interpolation=Bilinear average create title=[" + outM + "]");
    if (th != 0) {
        selectImage(outT);
        run("Rotate... ", "angle=" + th + " grid=1 interpolation=Bilinear");
        selectImage(outM);
        run("Rotate... ", "angle=" + th + " grid=1 interpolation=Bilinear");
    }
    // Keep fully valid pixels only, at least SIG2 away from empty areas (band-pass edge artefacts)
    selectImage(outM);
    run("Subtract...", "value=0.999");
    run("Multiply...", "value=1e9");
    run("Max...", "value=1");
    run("Min...", "value=0");
    run("Minimum...", "radius=" + SIG2);
    imageCalculator("Multiply", outT, outM);
}

// Masked normalised cross-correlation (Padfield 2012) of template T (mask MT) over image I (mask MI),
// computed with FFTs (FD Math). Only positions where the overlap covers at least minFrac of the valid
// template area are considered. wr > 0: only positions within +-wr of (wx, wy) are searched.
// Returns newArray(score, x, y, overlapFrac, secondScore):
// (x, y) = sub-pixel position of the template's top-left corner in I (may be negative = partly outside),
// secondScore = best score farther than 2*SIG2 from the peak (in the search window).
function maskedNCC(T, MT, I, MI, minFrac, wx, wy, wr) {
    selectImage(T);
    tw = getWidth();
    th = getHeight();
    selectImage(MT);
    getRawStatistics(nPix, meanMT);
    areaT = nPix * meanMT;
    selectImage(I);
    iw = getWidth();
    ih = getHeight();
    N = 2;
    while (N < maxOf(iw + tw, ih + th)) N = N * 2;
    padCanvas(T, "c_T", N);
    padCanvas(MT, "c_MT", N);
    padCanvas(I, "c_I", N);
    padCanvas(MI, "c_MI", N);
    imageCalculator("Multiply create 32-bit", "c_T", "c_T");
    rename("c_T2");
    imageCalculator("Multiply create 32-bit", "c_I", "c_I");
    rename("c_I2");
    // Correlations: value at (N/2 + u) = sum over x of image(x + u) * template(x)
    fdCorrelate("c_MI", "c_MT", "r_n");
    fdCorrelate("c_MI", "c_T", "r_sT");
    fdCorrelate("c_MI", "c_T2", "r_sT2");
    fdCorrelate("c_I", "c_MT", "r_sI");
    fdCorrelate("c_I2", "c_MT", "r_sI2");
    fdCorrelate("c_I", "c_T", "r_sTI");
    closeIfOpen("c_T"); closeIfOpen("c_MT"); closeIfOpen("c_I"); closeIfOpen("c_MI"); closeIfOpen("c_T2"); closeIfOpen("c_I2");

    // Valid positions: overlap >= minFrac of the template area
    selectImage("r_n");
    run("Duplicate...", "title=r_ok");
    run("Subtract...", "value=" + (minFrac * areaT));
    run("Multiply...", "value=1e9");
    run("Max...", "value=1");
    run("Min...", "value=0");
    selectImage("r_n");
    run("Min...", "value=1");
    // numerator = sTI - sT*sI/n ; varT = sT2 - sT^2/n ; varI = sI2 - sI^2/n
    imageCalculator("Multiply create 32-bit", "r_sT", "r_sI");
    rename("r_tmp");
    imageCalculator("Divide", "r_tmp", "r_n");
    imageCalculator("Subtract", "r_sTI", "r_tmp");
    close("r_tmp");
    imageCalculator("Multiply create 32-bit", "r_sT", "r_sT");
    rename("r_tmp");
    imageCalculator("Divide", "r_tmp", "r_n");
    imageCalculator("Subtract", "r_sT2", "r_tmp");
    close("r_tmp");
    imageCalculator("Multiply create 32-bit", "r_sI", "r_sI");
    rename("r_tmp");
    imageCalculator("Divide", "r_tmp", "r_n");
    imageCalculator("Subtract", "r_sI2", "r_tmp");
    close("r_tmp");
    imageCalculator("Multiply", "r_sT2", "r_sI2");
    selectImage("r_sT2");
    run("Min...", "value=1e-20");
    run("Square Root");
    imageCalculator("Divide", "r_sTI", "r_sT2");
    selectImage("r_sTI");
    run("Max...", "value=1");
    run("Min...", "value=-1");
    // Invalid positions -> -1
    run("Add...", "value=1");
    imageCalculator("Multiply", "r_sTI", "r_ok");
    selectImage("r_sTI");
    run("Subtract...", "value=1");

    // Peak (first pixel at the maximum) and second best score farther than 'rad' from it
    rad = 2 * SIG2;
    if (wr <= 0) {
        getRawStatistics(nPix, mean, mn, best);
        setThreshold(best, 1e30);
        run("Create Selection");
        getSelectionBounds(px, py, bw, bh);
        run("Select None");
        resetThreshold();
        dx = parabolaPeak(getPixel(px - 1, py), best, getPixel(px + 1, py));
        dy = parabolaPeak(getPixel(px, py - 1), best, getPixel(px, py + 1));
        makeOval(px - rad, py - rad, 2 * rad + 1, 2 * rad + 1);
        run("Set...", "value=-1");
        run("Select None");
        getRawStatistics(nPix, mean, mn, second);
    } else {
        // Search window: position u is stored at pixel (u + N/2) modulo N
        best = -2;
        px = 0;
        py = 0;
        for (v = round(wy - wr); v <= round(wy + wr); v++) {
            qy = ((v + N / 2) % N + N) % N;
            for (u = round(wx - wr); u <= round(wx + wr); u++) {
                q = getPixel(((u + N / 2) % N + N) % N, qy);
                if (q > best) { best = q; px = ((u + N / 2) % N + N) % N; py = qy; }
            }
        }
        dx = parabolaPeak(getPixel(px - 1, py), best, getPixel(px + 1, py));
        dy = parabolaPeak(getPixel(px, py - 1), best, getPixel(px, py + 1));
        second = -1;
        for (v = round(wy - wr); v <= round(wy + wr); v++) {
            qy = ((v + N / 2) % N + N) % N;
            for (u = round(wx - wr); u <= round(wx + wr); u++) {
                qx = ((u + N / 2) % N + N) % N;
                if (abs(qx - px) > rad || abs(qy - py) > rad) second = maxOf(second, getPixel(qx, qy));
            }
        }
    }
    selectImage("r_n");
    frac = getPixel(px, py) / areaT;
    closeIfOpen("r_n"); closeIfOpen("r_ok"); closeIfOpen("r_sT"); closeIfOpen("r_sT2");
    closeIfOpen("r_sI"); closeIfOpen("r_sI2"); closeIfOpen("r_sTI");

    // Position of the peak -> template offset u in I (the correlation is circular)
    ux = px - N / 2;
    uy = py - N / 2;
    if (ux < -(tw - 1)) ux = ux + N;
    if (ux > iw - 1) ux = ux - N;
    if (uy < -(th - 1)) uy = uy + N;
    if (uy > ih - 1) uy = uy - N;
    return newArray(best, ux + dx, uy + dy, frac, second);
}

// Copy of image 'src' at the top-left of an N x N canvas filled with 0
function padCanvas(src, title, N) {
    selectImage(src);
    run("Select None");
    run("Duplicate...", "title=[" + title + "]");
    run("Canvas Size...", "width=" + N + " height=" + N + " position=Top-Left zero");
}

// Circular cross-correlation of two N x N images with FD Math (result 'r')
function fdCorrelate(img, tpl, r) {
    run("FD Math...", "image1=[" + img + "] operation=Correlate image2=[" + tpl + "] result=[" + r + "] do");
}

// Sub-pixel offset (-0.5..0.5) of a peak from its value and its two neighbours
function parabolaPeak(a, b, c) {
    den = a - 2 * b + c;
    if (den >= 0) return 0;
    d = 0.5 * (a - c) / den;
    return maxOf(-0.5, minOf(0.5, d));
}

// Centre of the DHM area in full-resolution source pixels, from the template position (x, y) in the
// down-sampled features (template size tw x th, source size sW x sH)
function centreOf(x, y, tw, th, sW, sH) {
    fx = sW / round(sW / DS);
    fy = sH / round(sH / DS);
    return newArray((x + tw / 2) * fx, (y + th / 2) * fy);
}

// True if the DHM area (dW x dH DHM pixels, scale s, rotation th, centred at xc, yc) lies inside
// a sW x sH image, with a tolerance of 'tol' pixels
function insideImage(xc, yc, dW, dH, s, th, sW, sH, tol) {
    a = th * PI / 180;
    ex = 0.5 * s * (dW * abs(cos(a)) + dH * abs(sin(a)));
    ey = 0.5 * s * (dW * abs(sin(a)) + dH * abs(cos(a)));
    return (xc - ex >= -tol && xc + ex <= sW + tol && yc - ey >= -tol && yc + ey <= sH + tol);
}

// Scale and rotation of the DHM image measured on one well ("dhm" + "feat"/"featMask" open).
// First well (sInit = NaN): coarse scan of the scale (0.80-1.20 x nominal), then of the rotation (-3..3°),
// then fine scans. Next wells: fine scans around sInit/thInit only. Fixed values (sFix/thFix) are not scanned.
// Returns newArray(score, s, th, x, y, overlapFrac, secondScore)
function calibrate(sNom, sFix, thFix, sInit, thInit, signed) {
    best = newArray(-2, 0, 0, 0, 0, 0, 0);
    s0 = sInit;
    t0 = thInit;
    if (!isNaN(sFix)) s0 = sFix;
    if (!isNaN(thFix)) t0 = thFix;
    if (isNaN(t0)) t0 = 0;
    // (arrays are passed to scanST as variables: the macro language does not accept newArray() as an argument)
    s1 = newArray(1);
    t1 = newArray(1);
    if (isNaN(s0)) {
        sl = newArray(21);
        for (i = 0; i < sl.length; i++) sl[i] = sNom * (0.80 + 0.02 * i);
        t1[0] = t0;
        best = scanST(sl, t1, signed, best);
        s0 = best[1];
        if (isNaN(thFix)) {
            tl = newArray(13);
            for (i = 0; i < tl.length; i++) tl[i] = -3 + 0.5 * i;
            s1[0] = s0;
            best = scanST(s1, tl, signed, best);
            t0 = best[2];
        }
    }
    if (isNaN(sFix)) {
        sl = newArray(9);
        for (i = 0; i < sl.length; i++) sl[i] = s0 * (0.98 + 0.005 * i);
        t1[0] = t0;
        best = scanST(sl, t1, signed, best);
        s0 = best[1];
    }
    if (isNaN(thFix)) {
        tl = newArray(9);
        for (i = 0; i < tl.length; i++) tl[i] = t0 - 1 + 0.25 * i;
        s1[0] = s0;
        best = scanST(s1, tl, signed, best);
    }
    if (best[0] == -2) {
        s1[0] = s0;
        t1[0] = t0;
        best = scanST(s1, t1, signed, best);
    }
    return best;
}

// Registers the DHM template for every scale in sl and rotation in tl; keeps the best
function scanST(sl, tl, signed, best) {
    for (i = 0; i < sl.length; i++) {
        for (j = 0; j < tl.length; j++) {
            features("dhm", sl[i] / DS, tl[j], signed, "tpl", "tplMask");
            r = maskedNCC("tpl", "tplMask", "feat", "featMask", 0.5, 0, 0, 0);
            closeIfOpen("tpl");
            closeIfOpen("tplMask");
            if (r[0] > best[0]) best = newArray(r[0], sl[i], tl[j], r[1], r[2], r[3], r[4]);
        }
    }
    return best;
}

// Registers the DHM template ("tpl"/"tplMask") in image 'path', opened as 'title' (left open for cropping).
// wr > 0: only DHM centres within +-wr pixels of (xc, yc) are searched (full-resolution pixels of the image).
// Returns newArray(score, centreX, centreY, overlapFrac, secondScore, imageWidth, imageHeight)
function registerIn(path, title, signed, flat, minFrac, xc, yc, wr) {
    openSource(path, title, signed, flat);
    sW = getWidth();
    sH = getHeight();
    selectImage("tpl");
    tw = getWidth();
    th = getHeight();
    fx = sW / round(sW / DS);
    fy = sH / round(sH / DS);
    r = maskedNCC("tpl", "tplMask", "feat", "featMask", minFrac, xc / fx - tw / 2, yc / fy - th / 2, wr / DS);
    closeIfOpen("feat");
    closeIfOpen("featMask");
    c = centreOf(r[1], r[2], tw, th, sW, sH);
    return newArray(r[0], c[0], c[1], r[3], r[4], sW, sH);
}

// Crops BF and PC of a well around the DHM centre (xc, yc) of the source 'src' ("field" or "partial":
// single field, "stitched": stitched images), saves them and the QC overlay ("dhm" must be open).
// Returns a note listing the missing channels ("" if none).
function cropWell(src, xc, yc, fFiles, stFiles, stDirs, outDir, dhmFile, regC, s, theta, dhmGrid, saveQC) {
    chNames = newArray("Brightfield", "Phase Contrast");
    chTags = newArray("BF", "PC");
    base = substring(dhmFile, 0, lastIndexOf(dhmFile, "."));
    selectImage("dhm");
    dW = getWidth();
    dH = getHeight();
    getPixelSize(du, dpw, dph);
    files = fFiles;
    srcTitle = "fld";
    if (src == "stitched") {
        files = stFiles;
        srcTitle = "st";
    }
    missing = "";
    for (c = 0; c < 2; c++) {
        if (files[c] == "") {
            missing = appendNote(missing, "no " + chNames[c] + " image");
            continue;
        }
        if (c == regC && isOpen(srcTitle)) {
            selectImage(srcTitle);
        } else {
            if (src == "stitched") {
                open("" + stDirs[c] + files[c]);
            } else {
                open("" + files[c]);
                if (needsFlatField("" + files[c], c)) flatField();
            }
            rename("other");
        }
        if (src != "stitched" && c == 0 && BFMODE == 0 && needsFlatField("" + files[c], c))
            missing = appendNote(missing, "no corrected BF image: raw BF corrected by the macro");
        getPixelSize(su, spw, sph);
        cropTitle = "crop_" + chTags[c];
        cropToDHM(getTitle(), xc, yc, dW, dH, s, theta, dhmGrid, cropTitle);
        if (dhmGrid) run("Properties...", "unit=" + du + " pixel_width=" + dpw + " pixel_height=" + dph + " voxel_depth=1");
        else run("Properties...", "unit=" + su + " pixel_width=" + spw + " pixel_height=" + sph + " voxel_depth=1");
        saveAs("Tiff", outDir + chNames[c] + "/" + base + "_" + chTags[c] + ".tif");
        rename(cropTitle);
        closeIfOpen("other");
    }
    if (saveQC) {
        qc = "";
        if (isOpen("crop_PC")) qc = "crop_PC";
        else if (isOpen("crop_BF")) qc = "crop_BF";
        if (qc != "") saveOverlay("dhm", qc, outDir + "QC/" + base + "_QC.jpg");
    }
    return missing;
}

// File names of the 2 channels (BF, PC) of a well; key = field number (single field) or "st" (stitched image)
function wellFiles(well, key) {
    f = newArray(2);
    for (c = 0; c < 2; c++) f[c] = List.get(well + "|" + key + "|" + c);
    return f;
}

// Full paths of the single-field images (BF, PC) of a well ("" = missing). With BFMODE 0, BF comes from
// the background-corrected folder when the corrected image exists.
function fieldPaths(well, fldStr) {
    p = newArray(2);
    for (c = 0; c < 2; c++) {
        n = List.get(well + "|" + fldStr + "|" + c);
        if (n != "") p[c] = BFPCDIR + n;
    }
    if (BFMODE == 0) {
        n = List.get(well + "|" + fldStr + "|bc");
        if (n != "") p[0] = BFCORRDIR + n;
    }
    return p;
}

// True if the single-field image 'path' of channel c is a raw BF image that this macro must correct
function needsFlatField(path, c) {
    if (c != 0 || BFMODE == 2 || path == "") return false;
    if (BFMODE == 0 && startsWith(path, BFCORRDIR)) return false;
    return true;
}

// Background correction of the current raw brightfield image (in place), as in the
// Processed_BG_Corrected_Brightfield images: division by a Gaussian-blurred copy (sigma BF_SIGMA),
// contrast stretch (BF_SAT % saturated pixels) and conversion to 16-bit
function flatField() {
    id = getImageID();
    run("32-bit");
    run("Duplicate...", "title=ff_blur");
    blurId = getImageID();
    run("Gaussian Blur...", "sigma=" + BF_SIGMA);
    imageCalculator("Divide", id, blurId);
    selectImage(blurId);
    close();
    selectImage(id);
    run("Enhance Contrast", "saturated=" + BF_SAT);
    run("16-bit");
}

function sourceLabel(src, fldStr) {
    if (src == "field") return "fld " + fldStr;
    if (src == "partial") return "fld " + fldStr + " (partial)";
    if (src == "stitched") return "stitched fld 1-4";
    return "none";
}

// Position (top-left corner, full-resolution pixels) of the single field in the stitched image, measured
// on up to 3 wells by registering the field in the stitched image (same acquisition: high scores).
// Returns newArray(lowest score, x, y) or newArray(-1, 0, 0) if no well has both images.
function fieldOffset(wells, fldStr, regC, stDirs, signed) {
    xs = newArray(0);
    ys = newArray(0);
    scMin = 1;
    for (w = 0; w < wells.length && xs.length < 3; w++) {
        f = fieldPaths("" + wells[w], fldStr);
        st = wellFiles("" + wells[w], "st");
        if (f[regC] == "" || st[regC] == "") continue;
        openSource("" + f[regC], "f5", signed, needsFlatField("" + f[regC], regC));
        selectImage("feat");
        rename("ftpl");
        selectImage("featMask");
        rename("ftplMask");
        close("f5");
        openSource("" + stDirs[regC] + st[regC], "st", signed, false);
        sW = getWidth();
        sH = getHeight();
        r = maskedNCC("ftpl", "ftplMask", "feat", "featMask", 0.9, 0, 0, 0);
        x = r[1] * sW / round(sW / DS);
        y = r[2] * sH / round(sH / DS);
        xs = Array.concat(xs, x);
        ys = Array.concat(ys, y);
        scMin = minOf(scMin, r[0]);
        closeIfOpen("ftpl");
        closeIfOpen("ftplMask");
        closeIfOpen("feat");
        closeIfOpen("featMask");
        closeIfOpen("st");
    }
    if (xs.length == 0) return newArray(-1, 0, 0);
    mx = medianOf(xs);
    my = medianOf(ys);
    return newArray(scMin, mx, my);
}

// Least-squares plane v = a + b * col + c * row over the wells with use[i] true.
// Returns newArray(a, b, c), or NaNs if fewer than 6 wells or if they do not span 2 rows and 2 columns.
function fitPlane(col, row, v, use) {
    n = 0; sc = 0; sr = 0; scc = 0; srr = 0; scr = 0; sv = 0; scv = 0; srv = 0;
    for (i = 0; i < v.length; i++) {
        if (!use[i]) continue;
        n++;
        sc += col[i]; sr += row[i];
        scc += col[i] * col[i]; srr += row[i] * row[i]; scr += col[i] * row[i];
        sv += v[i]; scv += col[i] * v[i]; srv += row[i] * v[i];
    }
    // Normal equations [n sc sr; sc scc scr; sr scr srr] * [a b c] = [sv scv srv], solved by Cramer's rule
    det = n * (scc * srr - scr * scr) - sc * (sc * srr - scr * sr) + sr * (sc * scr - scc * sr);
    if (n < 6 || abs(det) < 1e-6 * maxOf(1, n * n * n)) return newArray(NaN, NaN, NaN);
    a = (sv * (scc * srr - scr * scr) - sc * (scv * srr - scr * srv) + sr * (scv * scr - scc * srv)) / det;
    b = (n * (scv * srr - scr * srv) - sv * (sc * srr - scr * sr) + sr * (sc * srv - scv * sr)) / det;
    c = (n * (scc * srv - scv * scr) - sc * (sc * srv - scv * sr) + sv * (sc * scr - scc * sr)) / det;
    return newArray(a, b, c);
}

// Distance (px) between a position (x, y) and the plate-model position of the well (col, row)
function planeDev(cX, cY, col, row, x, y) {
    return sqrt(pow(x - (cX[0] + cX[1] * col + cX[2] * row), 2) + pow(y - (cY[0] + cY[1] * col + cY[2] * row), 2));
}

// Converts the row letters of a well name (e.g. "B - 03") to a row index (A = 1, B = 2...)
function rowIndex(well) {
    v = 0;
    for (i = 0; i < lengthOf(well); i++) {
        p = indexOf("ABCDEFGHIJKLMNOPQRSTUVWXYZ", toUpperCase(substring(well, i, i + 1)));
        if (p < 0) return v;
        v = v * 26 + p + 1;
    }
    return v;
}

function calReason(score, calMin, fits, fldStr) {
    if (score < calMin) return "score below " + d2s(calMin, 2);
    return "DHM area not entirely inside fld " + fldStr;
}

// Crops image 'src' to the DHM area centred at (xc, yc) and leaves the result open as 'title'.
// dhmGrid: rotate by -th and resample by 1/s -> dW x dH image on the DHM pixel grid.
// Otherwise: axis-aligned crop of round(dW*s) x round(dH*s) source pixels.
// Areas outside the source image are 0.
function cropToDHM(src, xc, yc, dW, dH, s, th, dhmGrid, title) {
    if (dhmGrid) {
        a = th * PI / 180;
        pad = 4;
        rw = round(s * (dW * abs(cos(a)) + dH * abs(sin(a)))) + 2 * pad;
        rh = round(s * (dW * abs(sin(a)) + dH * abs(cos(a)))) + 2 * pad;
        copyRegion(src, round(xc - rw / 2), round(yc - rh / 2), rw, rh, "crop_region");
        if (th != 0) run("Rotate... ", "angle=" + (-th) + " grid=1 interpolation=Bilinear");
        nw = round(rw / s);
        nh = round(rh / s);
        run("Scale...", "x=- y=- width=" + nw + " height=" + nh + " interpolation=Bilinear create title=[" + title + "]");
        close("crop_region");
        selectImage(title);
        makeRectangle(round((nw - dW) / 2), round((nh - dH) / 2), dW, dH);
        run("Crop");
        run("Select None");
    } else {
        cw = round(dW * s);
        ch = round(dH * s);
        copyRegion(src, round(xc - cw / 2), round(yc - ch / 2), cw, ch, title);
    }
}

// Copies the rectangle (x0, y0, w, h) of 'src' into a new image 'title'; parts outside 'src' are 0
function copyRegion(src, x0, y0, w, h, title) {
    selectImage(src);
    sw = getWidth();
    sh = getHeight();
    newImage(title, bitDepthName(bitDepth()) + " black", w, h, 1);
    ix0 = maxOf(x0, 0);
    iy0 = maxOf(y0, 0);
    ix1 = minOf(x0 + w, sw);
    iy1 = minOf(y0 + h, sh);
    if (ix1 > ix0 && iy1 > iy0) {
        selectImage(src);
        makeRectangle(ix0, iy0, ix1 - ix0, iy1 - iy0);
        run("Copy");
        run("Select None");
        selectImage(title);
        makeRectangle(ix0 - x0, iy0 - y0, ix1 - ix0, iy1 - iy0);
        run("Paste");
        run("Select None");
    }
    selectImage(title);
}

// Saves a 1/3-size RGB overlay: DHM image in magenta, BF/PC crop in green
function saveOverlay(dhm, crop, path) {
    selectImage(dhm);
    run("Select None");
    w = round(getWidth() / 3);
    h = round(getHeight() / 3);
    run("Scale...", "x=- y=- width=" + w + " height=" + h + " interpolation=Bilinear average create title=qc_dhm");
    run("Enhance Contrast", "saturated=0.5");
    run("8-bit");
    selectImage(crop);
    run("Select None");
    run("Scale...", "x=- y=- width=" + w + " height=" + h + " interpolation=Bilinear average create title=qc_tl");
    run("Enhance Contrast", "saturated=0.5");
    run("8-bit");
    run("Merge Channels...", "c2=qc_tl c6=qc_dhm");
    saveAs("Jpeg", path);
    close();
}

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

// Prints to the Log (and to LOGFILE when set)
function logMsg(s) {
    print(s);
    if (LOGFILE != "") File.append(s, LOGFILE);
}

function appendNote(note, s) {
    if (s == "") return note;
    if (note == "") return s;
    return note + "; " + s;
}

function noteSuffix(note) {
    if (note == "") return "";
    return "  [" + note + "]";
}

function gridName(dhmGrid) {
    if (dhmGrid) return "DHM";
    return "BF/PC";
}

function closeIfOpen(title) {
    if (isOpen(title)) close(title);
}

// Closes the images opened by this macro (other open images are left untouched)
function closeWork() {
    t = newArray("dhm", "dhm_f", "dhm_m", "tpl", "tplMask", "feat", "featMask", "src", "fld", "st", "other", "crop_BF", "crop_PC", "crop_region");
    for (i = 0; i < t.length; i++) closeIfOpen(t[i]);
}

// Converts a pixel size to µm from its ImageJ unit
function toMicron(unit, v) {
    u = toLowerCase(unit);
    if (u == "cm") return v * 1e4;
    if (u == "mm") return v * 1e3;
    if (u == "nm") return v * 1e-3;
    if (u == "m" || u == "meter") return v * 1e6;
    return v;
}

// Normalizes file paths to ensure compatibility across Windows/Mac/Linux
function normalizeDir(d) {
    d = replace(d, "\\\\", "/");
    if (!endsWith(d, "/"))
        d = d + "/";
    return d;
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
