/*
 * Batch_Stitch_Plate.ijm
 *
 * Batch version of Stitch_single_registered_Tiles.ijm: stitches every well of a plate
 * acquisition and names the results after their well position.
 *
 * Expected layout:
 *
 *   <acquisition>/
 *     experimental_info.json          <- read for InitialPosition (Line, Column)
 *     <input folder>/                 <- the folder you select
 *       stitched_tiles/               <- created by this macro, holds
 *                                        B03_00001_00001.tif, B04_00001_00002.tif, ...
 *       RRRRR_CCCCC/                  <- one folder per well (R = line, C = column)
 *         00001_00001/Registered/00000_reg.tif
 *         00001_00002/Registered/00000_reg.tif
 *         00002_00001/Registered/00000_reg.tif
 *         00002_00002/Registered/00000_reg.tif
 *       ...
 *
 * For every well folder it:
 *   1. rotates the 4 registered tiles 90 degrees right and writes them next to
 *      them as 00000_reg1..4.tif (inside the well folder),
 *   0. (once per run) measures the micrometre-to-pixel scale by stitching a few
 *      wells spread across the plate and comparing the refined step in pixels
 *      with the stage step in micrometres. experimental_info.json cannot be
 *      trusted for this: the 40x acquisitions still report Magnification 20.0
 *      and PixelXSize_um 0.3, which would halve the seed and clamp every well.
 *   2. seeds the 2 x 2 grid from that well's recorded stage position (read from
 *      timestamps.txt in the raw acquisition tree) and runs Grid/Collection
 *      stitching with compute_overlap to refine it. The refinement is accepted
 *      only if every tile stayed within maxShift px of the seed; otherwise the
 *      well is re-stitched with compute_overlap OFF, which pins every tile at
 *      the stage seed. That is the only path in the plugin that honours the
 *      nominal offsets - with compute_overlap ON, a tile whose links are all
 *      rejected is written at (0,0), stacked on tile 1,
 *   3. applies an auto brightness/contrast (the B&C "Auto" button),
 *   4. saves the fused image into <input folder>/stitched_tiles/ as
 *      <Row><Col>_<well folder>.tif, e.g. B03_00001_00001.tif (the folder is
 *      created if it does not exist),
 *   5. deletes the 4 intermediate tiles, and writes a per-well qc_report.csv
 *      (seed source, step, overlap, max deviation, verdict) next to the results.
 *
 * Verdicts: REFINED  = phase correlation accepted, within maxShift of the seed
 *           SEEDED   = refinement rejected, tiles pinned at the stage seed
 *           UNCHECKED= registered positions unreadable, refinement kept as-is
 *           FAILED   = no fused image produced
 *
 * Well naming: folder RRRRR_CCCCC maps to
 *     line   = InitialPosition.Line   + R - 1   ->  A, B, C, ...
 *     column = InitialPosition.Column + C - 1   ->  01, 02, 03, ...
 * so with InitialPosition = {Line: 2, Column: 3}, folder 00001_00001 is written
 * as B03_00001_00001.tif.
 *
 * Install: copy into Fiji.app/plugins/ -> Plugins > Batch Stitch Plate
 * Or open it in the Script Editor and press Run.
 *
 * Non-interactive use: pass the folder as the macro argument, optionally with the
 * overlap after a "|", e.g.
 *     runMacro("Batch_Stitch_Plate.ijm", "D:/data/2026-09-09 10-02-21/Registered|15");
 */

// ---------------------------------------------------------------- settings --
tileFolders  = newArray("00001_00001", "00001_00002", "00002_00001", "00002_00002");
subFolder    = "Registered";
sourceName   = "00000_reg.tif";
outBaseName  = "00000_reg";     // intermediates: 00000_reg1.tif .. 00000_reg4.tif
jsonName     = "experimental_info.json";
outFolder    = "stitched_tiles";   // created inside the input folder for the results
gridX        = 2;
gridY        = 2;
tileOverlap  = 15;              // fallback overlap % when no stage coordinates are found
useStageSeed = true;            // seed each well's grid from the recorded stage position
maxShift     = 60;              // px a tile may move away from the seed before the
                                // refinement is rejected and the seed is used instead.
                                // Measured on this plate: legitimate refinements move
                                // ~49 px (median) and 58 px (p95) from the stage seed,
                                // so 60 accepts 85 % of wells and clamps the rest.
autoCalibrate = true;           // measure um/px from a few wells instead of trusting
                                // (NB: "calibrate" alone is a built-in macro function,
                                //  so this variable must not be called that)
                                // experimental_info.json, whose Magnification and
                                // PixelXSize_um are wrong on the 40x acquisitions
                                // (they still report the 20x objective)
calibWells   = 5;               // wells sampled for that, spread across the plate
objectiveMag = 0;               // TRUE objective magnification, 0 = work it out.
                                // Set this when experimental_info.json names the wrong
                                // objective - the 40x acquisitions in this dataset all
                                // report Magnification 20.0. Everything derived from it
                                // (pixel size, seed step, overlap, output calibration)
                                // is then rescaled by jsonMagnification / objectiveMag.
pixelOverride = 0;              // um/px; > 0 overrides the JSON, objectiveMag and search
calibrateOutput = true;         // stamp the corrected pixel size onto the saved images
                                // (the source tiles carry no spatial calibration at all)
regThreshold = 0.30;            // stitching parameters, exposed so they are tunable
dispRelative = 2.50;            //   max/avg_displacement_threshold
dispAbsolute = 3.50;            //   absolute_displacement_threshold
skipExisting = false;           // true = leave wells whose <Row><Col>.tif already exists
cleanUpTiles = true;            // delete the intermediate tiles after a successful fuse
// -----------------------------------------------------------------------------

// Input: either passed as a macro argument ("path" or "path|overlap"), or asked for.
arg = getArgument();
if (lengthOf(arg) > 0) {
    bar = indexOf(arg, "|");
    if (bar < 0)
        inputDir = arg;
    else {
        inputDir = substring(arg, 0, bar);
        v = parseFloat(substring(arg, bar + 1));
        if (!isNaN(v))
            tileOverlap = v;
    }
} else {
    inputDir = getDirectory("Choose the folder containing the RRRRR_CCCCC well folders");
    if (lengthOf(inputDir) == 0)
        exit("No folder selected.");
    Dialog.create("Batch Stitch Plate");
    Dialog.addCheckbox("Seed the grid from the recorded stage position", useStageSeed);
    Dialog.addNumber("Objective magnification (0 = auto)", objectiveMag, 0, 5, "x");
    Dialog.addNumber("Max shift from seed", maxShift, 0, 5, "px");
    Dialog.addNumber("Tile overlap (only if no stage data)", tileOverlap, 1, 5, "%");
    Dialog.show();
    useStageSeed = Dialog.getCheckbox();
    objectiveMag = Dialog.getNumber();
    maxShift     = Dialog.getNumber();
    tileOverlap  = Dialog.getNumber();
}
if (isNaN(objectiveMag) || objectiveMag < 0)
    objectiveMag = 0;
if (isNaN(maxShift) || maxShift <= 0)
    exit("Max shift from seed must be greater than 0 (got " + maxShift + ").");
if (lengthOf(inputDir) == 0)
    exit("No folder selected.");
if (isNaN(tileOverlap) || tileOverlap < 0 || tileOverlap >= 100)
    exit("Tile overlap must be between 0 and 100 % (got " + tileOverlap + ").");
inputDir = normalizeDir(inputDir);

print("\\Clear");
print("Input folder: " + inputDir);
print("Tile overlap: " + tileOverlap + " %  (applied to every well)");

// ------------------------------------------- read the plate origin from JSON --
// Documented location is the parent of the input folder; the input folder itself
// and the grandparent are checked as a fallback.
parent = parentOf(inputDir);
grand  = parentOf(parent);
jsonPath = "";
if (lengthOf(parent) > 0 && File.exists(parent + jsonName))     jsonPath = parent + jsonName;
if (lengthOf(jsonPath) == 0 && File.exists(inputDir + jsonName)) jsonPath = inputDir + jsonName;
if (lengthOf(jsonPath) == 0 && lengthOf(grand) > 0 && File.exists(grand + jsonName))
    jsonPath = grand + jsonName;
if (lengthOf(jsonPath) == 0)
    exit("Could not find " + jsonName + " in the input folder, its parent or its grandparent.");
print("Using " + jsonPath);

json = File.openAsString(jsonPath);

ipIdx = indexOf(json, "\"InitialPosition\"");
if (ipIdx < 0)
    exit("No \"InitialPosition\" block in " + jsonPath);
ipBlock = substring(json, ipIdx);
brace = indexOf(ipBlock, "}");
if (brace > 0)
    ipBlock = substring(ipBlock, 0, brace);   // keep only the InitialPosition object

initLine   = jsonInt(ipBlock, "Line");
initColumn = jsonInt(ipBlock, "Column");
if (isNaN(initLine) || isNaN(initColumn))
    exit("Could not read Line/Column from the InitialPosition block in " + jsonPath);

print("Initial position: line " + initLine + " (" + rowLetter(initLine) + "), column "
      + initColumn + "  ->  first well is " + rowLetter(initLine) + IJ.pad(initColumn, 2));

// Optional sanity check against the declared acquisition size.
nLines = NaN;  nCols = NaN;
mrIdx = indexOf(json, "\"MeasurementRange\"");
if (mrIdx >= 0) {
    mrBlock = substring(json, mrIdx);
    brace = indexOf(mrBlock, "}");
    if (brace > 0)
        mrBlock = substring(mrBlock, 0, brace);
    nLines = jsonInt(mrBlock, "NumberOfLines");
    nCols  = jsonInt(mrBlock, "NumberOfColumns");
    if (!isNaN(nLines) && !isNaN(nCols))
        print("Measurement range: " + nLines + " lines x " + nCols + " columns");
}

// ------------------------------------------- stage-coordinate seeding set-up --
// The raw acquisition tree sits next to experimental_info.json and mirrors the well
// and tile folder names; each site folder holds a timestamps.txt whose last two
// columns are the stage X and Y in micrometres.
pixelUm = jsonNum(json, "PixelXSize_um");
jsonMag = jsonNum(json, "Magnification");
// Kept as two bare calls: a user function nested inside another user function's
// argument list hits the same interpreter type-inference trap as rowLetter() did.
rawDir  = parentOf2(jsonPath);
rawDir  = normalizeDir(rawDir);
// pixelUm is only the starting guess here - the calibration below measures the real
// value, so a missing or wrong one in the JSON is not fatal.
if (useStageSeed) {
    if (isNaN(pixelUm) || pixelUm <= 0)
        print("NOTE: no usable PixelXSize_um in " + jsonName
              + " - relying entirely on the calibration below");
    else
        print("Stage seeding ON: " + jsonName + " says " + pixelUm + " um/px, raw tree "
              + rawDir + ", max allowed shift from the seed " + maxShift + " px");
}

// ------------------------------------------------- collect the well folders --
list = getFileList(inputDir);
wells = newArray(0);
for (i = 0; i < list.length; i++) {
    name = replace(list[i], "[/\\\\]$", "");          // strip the trailing separator
    if (matches(name, "\\d+_\\d+") && File.isDirectory(inputDir + name))
        wells = Array.concat(wells, name);
}
if (wells.length == 0)
    exit("No RRRRR_CCCCC subfolders found in " + inputDir);
print("Well folders found: " + wells.length);

// ------------------------------------------------- output folder for results --
outDir = inputDir + outFolder + "/";
if (!File.exists(outDir))
    File.makeDirectory(outDir);
if (!File.isDirectory(outDir))
    exit("Could not create the output folder " + outDir);
print("Output folder: " + outDir);

// ------------------------------- calibrate the micrometre-to-pixel scale --
// experimental_info.json can name the wrong objective: the 40x acquisitions in this
// dataset still report Magnification 20.0 and PixelXSize_um 0.3, so a stage-derived
// seed comes out at half the true step and every well gets clamped to it. Instead of
// trusting that field, measure the scale: stitch a few wells with compute_overlap and
// compare the refined step in pixels with the stage step those tiles were taken at.
// It cannot bootstrap from the JSON value, because a wrong one produces a seed so far
// off that the refinement it is measured against is itself garbage (a 354 px seed on
// the 40x plate refined to 134 px with a 1082 px closure error). So the scale factor
// is SEARCHED first: the same probe well is stitched once per candidate objective
// ratio, and the candidate whose refinement agrees with its own seed wins.
// Declared up front: the macro language has no block scope, so anything referenced
// after the branches must exist whichever branch ran.
effPixelUm = pixelUm;
scaleSrc   = jsonName;
scaleNote  = "";
scaleFixed = false;     // true when the scale was stated rather than measured
probeUm    = NaN;
probeTw    = 0;
if (pixelOverride > 0) {
    effPixelUm = pixelOverride;
    scaleSrc   = "pixelOverride setting";
    scaleFixed = true;
} else if (useStageSeed && autoCalibrate && wells.length > 0 && !isNaN(pixelUm) && pixelUm > 0) {
    print("");
    print("--- calibrating um/px ---");

    // Wells sampled for calibration, spread across the plate.
    samp = newArray(calibWells);
    for (k = 0; k < calibWells; k++) {
        if (calibWells > 1)
            samp[k] = round(k * (wells.length - 1) / (calibWells - 1));
        else
            samp[k] = 0;
    }

    // Find a probe well: one with both stage coordinates and readable tiles.
    probeIdx = -1;
    for (si = 0; si < samp.length && probeTw == 0; si++) {
        cw = wells[samp[si]];
        su = stageStepUm(rawDir + cw + "/", tileFolders);
        if (lengthOf(su) == 0)
            print("  " + cw + ": no stage coordinates");
        else {
            uu = split(su, ",");
            tw = rotateTiles(inputDir + cw + "/", tileFolders, subFolder, sourceName, outBaseName);
            if (tw <= 0)
                print("  " + cw + ": tiles unavailable");
            else {
                probeUm  = parseFloat(uu[0]);
                probeTw  = tw;
                probeIdx = samp[si];
            }
        }
    }

    provisional = NaN;
    if (objectiveMag > 0 && !isNaN(jsonMag) && jsonMag > 0) {
        // A'. The objective is stated, so the scale is KNOWN. Neither the search nor
        //     the measurement below may override it - if the images happen to stitch
        //     badly, that is a reason to fall back to this seed, not to distrust it.
        provisional = pixelUm * jsonMag / objectiveMag;
        scaleFixed  = true;
        scaleNote   = "" + objectiveMag + "x objective (" + jsonName + " says " + jsonMag + "x)";
        print("  " + jsonName + " reports " + jsonMag + "x at " + pixelUm + " um/px");
        print("  you specified " + objectiveMag + "x  ->  corrected to "
              + d2s(provisional, 6) + " um/px   (search and measurement skipped)");
    } else if (probeTw > 0) {
        // A. Otherwise search the objective ratio on the probe well. x0.5 is what
        //    rescues a 40x acquisition whose metadata still names the 20x objective.
        candF = newArray(1, 0.5, 2, 0.25, 4);
        bestF = NaN;
        bestScore = 999999;
        cw    = wells[probeIdx];
        cwDir = inputDir + cw + "/";
        print("  probing objective ratios on " + cw
              + "  (stage step " + d2s(probeUm, 2) + " um, tile " + probeTw + " px)");
        for (fi = 0; fi < candF.length; fi++) {
            cand = pixelUm * candF[fi];
            st   = probeUm / cand;
            if (st > 0.3 * probeTw && st < 0.98 * probeTw) {
                close("*");
                File.delete(cwDir + "TileConfiguration.registered.txt");
                opt = stitchOptions(cwDir, outBaseName, gridX, gridY,
                                    100 * (probeTw - st) / probeTw,
                                    regThreshold, dispRelative, dispAbsolute, 1);
                run("Grid/Collection stitching", opt);
                close("*");
                rs = refinedStep(cwDir, outBaseName, tileFolders.length);
                if (lengthOf(rs) > 0) {
                    vv  = split(rs, ",");
                    sxp = parseFloat(vv[0]);
                    syp = parseFloat(vv[1]);
                    rr  = parseFloat(vv[2]);
                    // A correct seed is one the refinement barely moves.
                    score = rr + abs(sxp - st) + abs(syp - st);
                    print("    x" + candF[fi] + ": seed " + d2s(st, 1)
                          + " px -> refined (" + d2s(sxp, 1) + ", " + d2s(syp, 1)
                          + "), closure " + d2s(rr, 1) + "   score " + d2s(score, 1));
                    if (rr < 20 && sxp > 0.3 * probeTw && sxp < probeTw && score < bestScore) {
                        bestScore = score;
                        bestF     = candF[fi];
                    }
                } else
                    print("    x" + candF[fi] + ": no registered positions");
                run("Collect Garbage");
            }
        }
        if (!isNaN(bestF)) {
            provisional = pixelUm * bestF;
            scaleNote   = "objective-ratio probe (x" + bestF + ")";
            print("  best ratio x" + bestF + "  ->  " + d2s(provisional, 6)
                  + " um/px (provisional)");
        }
    }

    if (isNaN(provisional))
        print("  could not establish a scale - set objectiveMag or pixelOverride");
    else if (scaleFixed) {
        effPixelUm = provisional;
        scaleSrc   = scaleNote;
    } else {

        // B. with a sane seed, measure the scale properly across the sampled wells.
        got = newArray(0);
        for (k = 0; k < samp.length; k++) {
            cw    = wells[samp[k]];
            cwDir = inputDir + cw + "/";
            su    = stageStepUm(rawDir + cw + "/", tileFolders);
            if (lengthOf(su) > 0) {
                uu  = split(su, ",");
                umX = parseFloat(uu[0]);
                tw  = rotateTiles(cwDir, tileFolders, subFolder, sourceName, outBaseName);
                if (tw > 0 && umX > 0) {
                    st = umX / provisional;
                    close("*");
                    File.delete(cwDir + "TileConfiguration.registered.txt");
                    opt = stitchOptions(cwDir, outBaseName, gridX, gridY,
                                        100 * (tw - st) / tw,
                                        regThreshold, dispRelative, dispAbsolute, 1);
                    run("Grid/Collection stitching", opt);
                    close("*");
                    rs = refinedStep(cwDir, outBaseName, tileFolders.length);
                    if (lengthOf(rs) > 0) {
                        vv    = split(rs, ",");
                        stepP = parseFloat(vv[0]);
                        resid = parseFloat(vv[2]);
                        if (stepP > 0.3 * tw && stepP < tw && resid < 20) {
                            sc  = umX / stepP;
                            got = Array.concat(got, sc);
                            print("  " + cw + ": " + d2s(umX, 2) + " um measured as "
                                  + d2s(stepP, 1) + " px  ->  " + d2s(sc, 6)
                                  + " um/px   (closure " + d2s(resid, 1) + " px)");
                        } else
                            print("  " + cw + ": rejected (step " + d2s(stepP, 1)
                                  + " px, closure " + d2s(resid, 1) + " px)");
                    }
                    run("Collect Garbage");
                }
            }
        }
        if (got.length >= 2) {
            effPixelUm = medianOf(got);
            scaleSrc   = "" + got.length + "-well calibration";
        } else {
            effPixelUm = provisional;
            scaleSrc   = scaleNote;
            print("  too few wells refined cleanly - keeping " + scaleNote);
        }
    }
}
if (isNaN(effPixelUm) || effPixelUm <= 0) {
    print("WARNING: no usable pixel size - stage seeding disabled");
    useStageSeed = false;
} else {
    print("Effective pixel size: " + d2s(effPixelUm, 6) + " um/px  (from " + scaleSrc + ")");
    if (!isNaN(pixelUm) && pixelUm > 0) {
        ratio = pixelUm / effPixelUm;
        if (abs(ratio - 1) > 0.1)
            print("  NOTE: " + d2s(ratio, 2) + " x the value in " + jsonName
                  + " - its Magnification is probably wrong for this acquisition");
    }
}

// Stop before touching the plate if the seed is absurd. A 2 x 2 acquisition does not
// overlap by 60 %, and silently clamping every well to such a seed is how the 40x run
// produced 70 undersized images.
if (useStageSeed && !isNaN(probeUm) && probeTw > 0 && effPixelUm > 0) {
    chkStep = probeUm / effPixelUm;
    chkOv   = 100 * (probeTw - chkStep) / probeTw;
    print("Seed check: " + d2s(chkStep, 1) + " px step = " + d2s(chkOv, 1) + " % tile overlap");
    if (chkOv < 2 || chkOv > 50)
        exit("The seed implies " + d2s(chkOv, 1) + " % tile overlap, which is not a plausible\n"
           + "2 x 2 acquisition, so the pixel size is wrong.\n \n"
           + jsonName + " reports " + pixelUm + " um/px and the stage step is "
           + d2s(probeUm, 2) + " um.\n \n"
           + "Fix it by setting pixelOverride at the top of this macro to the real\n"
           + "um/px (for a 40x run whose metadata names the 20x objective that is\n"
           + "half the reported value), or set useStageSeed = false to fall back to\n"
           + "the tile overlap from the dialog.");
}

// ----------------------------------------------------------------- main loop --
nDone = 0;  nSkipped = 0;  nFailed = 0;  nClamped = 0;
tileW = 0;
qc = "well,id,seed,step_px,overlap_pct,max_dev_px,verdict\n";
setBatchMode(false);

for (w = 0; w < wells.length; w++) {
    well    = wells[w];
    wellDir = inputDir + well + "/";

    us   = indexOf(well, "_");
    row  = initLine   + parseInt(substring(well, 0, us))  - 1;
    col  = initColumn + parseInt(substring(well, us + 1)) - 1;
    // rowLetter() must stay in an assignment of its own. The macro interpreter
    // infers the type of an expression from its first term, so a user function
    // followed by "+" is parsed as numeric and rejects the returned string
    // ("Numeric return value expected"). A bare call is fine.
    rowLbl  = rowLetter(row);
    outName = rowLbl + IJ.pad(col, 2) + "_" + well + ".tif";
    outPath = outDir + outName;

    showProgress(w + 1, wells.length);
    showStatus("Stitching " + well + " -> " + outName);
    print("");
    print("[" + (w + 1) + "/" + wells.length + "] " + well + "  ->  " + outName);

    if ((!isNaN(nLines) && row > initLine + nLines - 1) || (!isNaN(nCols) && col > initColumn + nCols - 1))
        print("  WARNING: " + well + " falls outside the declared measurement range");

    // Decide whether this well can be processed.
    reason = "";
    for (i = 0; i < tileFolders.length; i++) {
        src = wellDir + tileFolders[i] + "/" + subFolder + "/" + sourceName;
        if (!File.exists(src))
            reason = reason + "\n    missing " + src;
    }
    if (lengthOf(reason) == 0 && skipExisting && File.exists(outPath))
        reason = "\n    " + outName + " already exists";

    if (lengthOf(reason) > 0) {
        print("  SKIPPED:" + reason);
        nSkipped++;
    } else {
        // 1. rotate the four tiles
        tileW = rotateTiles(wellDir, tileFolders, subFolder, sourceName, outBaseName);
        close("*");

        // 2. seed the grid from the stage coordinates of this well
        if (tileW <= 0)
            exit("Could not determine the tile width for " + well + ".");
        seedStep = NaN;
        seedSrc  = "dialog";
        if (useStageSeed && effPixelUm > 0 && lengthOf(rawDir) > 0) {
            su = stageStepUm(rawDir + well + "/", tileFolders);
            if (lengthOf(su) > 0) {
                uu = split(su, ",");
                // tile 2 is the right neighbour of tile 1, tile 3 the one below.
                stepX = parseFloat(uu[0]) / effPixelUm;
                stepY = parseFloat(uu[1]) / effPixelUm;
                if (stepX > 1 && stepY > 1 && stepX < tileW && stepY < tileW) {
                    if (abs(stepX - stepY) > 1)
                        print("  NOTE: stage steps differ between axes (" + d2s(stepX, 1) + " vs "
                              + d2s(stepY, 1) + " px); a grid layout can only carry one, using x");
                    seedStep = stepX;
                    seedSrc  = "stage";
                } else
                    print("  WARNING: implausible stage step (" + d2s(stepX, 1) + ", " + d2s(stepY, 1)
                          + " px) - falling back to the dialog overlap");
            }
        }
        if (isNaN(seedStep))
            seedStep = tileW * (1 - tileOverlap / 100);
        seedOverlap = 100 * (tileW - seedStep) / tileW;

        // 3. stitch. Pass 0 refines from the seed; if any tile moves further than
        //    maxShift px the refinement is rejected and pass 1 re-runs WITHOUT
        //    compute_overlap, which is the only code path in the plugin that places
        //    tiles at the nominal (here: stage-seeded) offsets.
        verdict = "";
        maxDev  = NaN;
        fused   = false;
        for (pass = 0; pass <= 1; pass++) {
            close("*");
            File.delete(wellDir + "TileConfiguration.registered.txt");   // never score a stale file

            withOverlap = 0;
            if (pass == 0)
                withOverlap = 1;
            options = stitchOptions(wellDir, outBaseName, gridX, gridY, seedOverlap,
                                    regThreshold, dispRelative, dispAbsolute, withOverlap);
            run("Grid/Collection stitching", options);

            if (isOpen("Fused"))
                selectWindow("Fused");
            else if (nImages > 0)
                selectImage(nImages);
            else {
                print("  ERROR: stitching produced no image (pass " + pass + ")");
                pass = 2;
            }

            if (nImages > 0) {
                if (pass == 1) {
                    // Deterministic placement at the seed - nothing left to check.
                    fused = true;
                    verdict = "SEEDED";
                    pass = 2;
                } else {
                    maxDev = seedDeviation(wellDir, outBaseName, tileFolders.length, seedStep);
                    if (isNaN(maxDev)) {
                        print("  WARNING: could not read back the registered positions"
                              + " - keeping the refined result unchecked");
                        fused = true;
                        verdict = "UNCHECKED";
                        pass = 2;
                    } else if (maxDev <= maxShift) {
                        fused = true;
                        verdict = "REFINED";
                        pass = 2;
                    } else {
                        print("  rejected: a tile moved " + d2s(maxDev, 1) + " px from the stage seed"
                              + " (limit " + maxShift + ") - re-running clamped to the seed");
                        nClamped++;
                    }
                }
            }
        }

        if (fused) {
            // 4. auto brightness/contrast, then save under the well name
            run("Enhance Contrast", "saturated=0.35");
            getMinAndMax(dispMin, dispMax);
            // The source tiles carry no spatial calibration, so stamp the corrected
            // pixel size on: without it a 40x image measures as if it were 20x.
            if (calibrateOutput && effPixelUm > 0)
                setVoxelSize(effPixelUm, effPixelUm, 1, "um");
            saveAs("Tiff", outPath);
            print("  " + verdict + "  seed=" + seedSrc + " step=" + d2s(seedStep, 1) + " px ("
                  + d2s(seedOverlap, 1) + "% overlap)  maxDev=" + d2s(maxDev, 1)
                  + "  ->  " + outName);
            nDone++;
        } else {
            verdict = "FAILED";
            nFailed++;
        }
        qc = qc + well + "," + rowLbl + IJ.pad(col, 2) + "," + seedSrc + ","
                + d2s(seedStep, 2) + "," + d2s(seedOverlap, 3) + "," + d2s(maxDev, 2) + ","
                + verdict + "\n";
        close("*");

        // 4. clean up, but only once the output is safely on disk
        if (cleanUpTiles && File.exists(outPath)) {
            for (i = 0; i < tileFolders.length; i++) {
                tmp = wellDir + outBaseName + (i + 1) + ".tif";
                File.delete(tmp);
                if (File.exists(tmp))
                    print("  WARNING: could not delete " + tmp);
            }
        }
        run("Collect Garbage");
    }
}

showProgress(1);
showStatus("");
print("");
print("=== Finished: " + nDone + " fused (" + nClamped + " clamped to the stage seed), "
      + nSkipped + " skipped, " + nFailed + " failed ===");
print("Pixel size used: " + d2s(effPixelUm, 6) + " um/px (from " + scaleSrc + ")");

// A handful of clamped wells is normal; almost all of them means the seed itself is
// wrong, which is what a bad pixel size in experimental_info.json looks like.
if (nDone > 0 && nClamped > 0.5 * nDone) {
    print("");
    print("*** " + nClamped + " of " + nDone + " wells were clamped to the seed.");
    if (scaleFixed) {
        print("*** The scale was stated (" + scaleSrc + "), so the seed geometry is");
        print("*** correct and those wells are placed at it - they are usable. What");
        print("*** this says is that phase correlation could not improve on the seed,");
        print("*** which at high magnification usually means too little structure in");
        print("*** the overlap strip. Raise maxShift only if you have checked the");
        print("*** refinements are genuinely better than the seed.");
    } else {
        print("*** That usually means the SEED is wrong, not the images. Check the");
        print("*** 'Effective pixel size' line above against the stage step, and set");
        print("*** objectiveMag (or pixelOverride) at the top of this macro.");
    }
}

// Written last, and to a free name: an open spreadsheet holding qc_report.csv must
// not throw away a finished run. File.delete on a locked file fails, which is the
// only probe the macro language offers.
qcPath = outDir + "qc_report.csv";
if (File.exists(qcPath)) {
    File.delete(qcPath);
    if (File.exists(qcPath)) {
        n = 1;
        while (n < 50 && File.exists(outDir + "qc_report_" + n + ".csv"))
            n++;
        qcPath = outDir + "qc_report_" + n + ".csv";
        print("qc_report.csv is locked by another program (close it in Excel);");
        print("writing to " + qcPath + " instead.");
    }
}
File.saveString(qc, qcPath);
print("Per-well verdicts: " + qcPath);

// ------------------------------------------------------------------ helpers --

// Normalise a directory path to forward slashes with a trailing slash.
function normalizeDir(d) {
    d = replace(d, "\\\\", "/");
    if (!endsWith(d, "/"))
        d = d + "/";
    return d;
}

// Parent of a normalised directory path, or "" if there is none.
function parentOf(d) {
    if (lengthOf(d) == 0)
        return "";
    d = substring(d, 0, lengthOf(d) - 1);     // drop the trailing slash
    i = lastIndexOf(d, "/");
    if (i < 1)
        return "";
    return substring(d, 0, i + 1);
}

// Parent of a FILE path (the directory holding it), normalised, or "".
function parentOf2(p) {
    i = lastIndexOf(p, "/");
    if (i < 1)
        return "";
    return substring(p, 0, i + 1);
}

// Path of the timestamps.txt for one raw tile folder, or "" if there is none.
// Normally <tile>/00001_00001/timestamps.txt; falls back to the first site folder
// that has one, and to the tile folder itself.
function stageFile(tileDir) {
    p = tileDir + "00001_00001/timestamps.txt";
    if (File.exists(p))
        return p;
    p = tileDir + "timestamps.txt";
    if (File.exists(p))
        return p;
    if (!File.isDirectory(tileDir))
        return "";
    l = getFileList(tileDir);
    for (i = 0; i < l.length; i++) {
        p = tileDir + l[i] + "timestamps.txt";
        if (File.exists(p))
            return p;
    }
    return "";
}

// "x,y" stage position in um from the first line of a timestamps.txt, or "".
// Line looks like:  00000 10:03:04.484 2026.09.09 0 18012.50 24550.60
function stageXY(path) {
    txt = File.openAsString(path);
    if (lengthOf(txt) == 0)
        return "";
    lines = split(txt, "\n");
    if (lines.length == 0)
        return "";
    f = split(lines[0]);
    if (f.length < 6)
        return "";
    x = parseFloat(f[f.length - 2]);
    y = parseFloat(f[f.length - 1]);
    if (isNaN(x) || isNaN(y))
        return "";
    return "" + x + "," + y;
}

// "stepXum,stepYum": the stage move from tile 1 to tile 2 and from tile 1 to
// tile 3, in micrometres. "" if any tile has no readable timestamps.txt.
function stageStepUm(rawWellDir, tiles) {
    n = tiles.length;
    if (n < 3)
        return "";
    xs = newArray(n);
    ys = newArray(n);
    for (i = 0; i < n; i++) {
        sf = stageFile(rawWellDir + tiles[i] + "/");
        if (lengthOf(sf) == 0)
            return "";
        xy = stageXY(sf);
        if (lengthOf(xy) == 0)
            return "";
        pp = split(xy, ",");
        xs[i] = parseFloat(pp[0]);
        ys[i] = parseFloat(pp[1]);
    }
    return "" + (xs[1] - xs[0]) + "," + (ys[2] - ys[0]);
}

// Rotates the source tiles of one well into wellDir as <base>1..N.tif.
// Returns the tile width after rotation, or 0 if any source is missing.
function rotateTiles(wellDir, tiles, sub, srcName, base) {
    for (i = 0; i < tiles.length; i++) {
        if (!File.exists(wellDir + tiles[i] + "/" + sub + "/" + srcName))
            return 0;
    }
    wpx = 0;
    setBatchMode(true);
    for (i = 0; i < tiles.length; i++) {
        open(wellDir + tiles[i] + "/" + sub + "/" + srcName);
        run("Rotate 90 Degrees Right");
        wpx = getWidth();          // after rotation; turns a step into an overlap %
        saveAs("Tiff", wellDir + base + (i + 1) + ".tif");
        close();
    }
    setBatchMode(false);
    return wpx;
}

// The Grid/Collection stitching options string. withCompute = 1 refines from the
// seed, 0 pins every tile at it (the only path that honours the nominal offsets).
function stitchOptions(dir, base, gx, gy, overlapPct, reg, rel, ab, withCompute) {
    o = "type=[Grid: row-by-row]"
      + " order=[Right & Down                ]"
      + " grid_size_x=" + gx
      + " grid_size_y=" + gy
      + " tile_overlap=" + d2s(overlapPct, 4)
      + " first_file_index_i=1"
      + " directory=[" + dir + "]"
      + " file_names=" + base + "{i}.tif"
      + " output_textfile_name=TileConfiguration.txt"
      + " fusion_method=[Linear Blending]"
      + " regression_threshold=" + reg
      + " max/avg_displacement_threshold=" + rel
      + " absolute_displacement_threshold=" + ab;
    if (withCompute == 1)
        o = o + " compute_overlap";
    o = o + " computation_parameters=[Save computation time (but use more RAM)]"
          + " image_output=[Fuse and display]";
    return o;
}

// "stepx,stepy,closureResidual" in px from a registered TileConfiguration, or "".
function refinedStep(wellDir, base, nTiles) {
    p = wellDir + "TileConfiguration.registered.txt";
    if (!File.exists(p) || nTiles < 4)
        return "";
    txt = File.openAsString(p);
    xs = newArray(nTiles);
    ys = newArray(nTiles);
    for (i = 0; i < nTiles; i++) {
        nm = base + (i + 1) + ".tif";
        s  = tcPos(txt, nm);
        if (lengthOf(s) == 0)
            return "";
        pp = split(s, ",");
        xs[i] = parseFloat(pp[0]);
        ys[i] = parseFloat(pp[1]);
    }
    rx = (xs[3] - xs[0]) - (xs[1] - xs[0]) - (xs[2] - xs[0]);
    ry = (ys[3] - ys[0]) - (ys[1] - ys[0]) - (ys[2] - ys[0]);
    return "" + (xs[1] - xs[0]) + "," + (ys[2] - ys[0]) + "," + sqrt(rx * rx + ry * ry);
}

// Median of a numeric array (the array itself is left untouched).
function medianOf(a) {
    b = Array.copy(a);
    Array.sort(b);
    m = b.length;
    if (m == 0)
        return NaN;
    if (m % 2 == 1)
        return b[floor(m / 2)];
    return (b[floor(m / 2) - 1] + b[floor(m / 2)]) / 2;
}

// "x,y" of one image in a TileConfiguration file, or "" if it is not listed.
function tcPos(txt, name) {
    lines = split(txt, "\n");
    for (i = 0; i < lines.length; i++) {
        if (startsWith(lines[i], name)) {
            o = indexOf(lines[i], "(");
            c = indexOf(lines[i], ")");
            if (o < 0 || c < o)
                return "";
            parts = split(substring(lines[i], o + 1, c), ",");
            if (parts.length < 2)
                return "";
            return "" + parseFloat(parts[0]) + "," + parseFloat(parts[1]);
        }
    }
    return "";
}

// Largest distance, over the tiles, between the registered position and the seed
// grid of the given step. NaN if the registered file cannot be read.
function seedDeviation(wellDir, base, nTiles, step) {
    p = wellDir + "TileConfiguration.registered.txt";
    if (!File.exists(p))
        return NaN;
    txt = File.openAsString(p);
    xs = newArray(nTiles);
    ys = newArray(nTiles);
    for (i = 0; i < nTiles; i++) {
        nm = base + (i + 1) + ".tif";
        s  = tcPos(txt, nm);
        if (lengthOf(s) == 0)
            return NaN;
        pp = split(s, ",");
        xs[i] = parseFloat(pp[0]);
        ys[i] = parseFloat(pp[1]);
    }
    worst = 0;
    for (i = 0; i < nTiles; i++) {
        // seed grid, row-by-row over a 2 x 2: (0,0) (step,0) (0,step) (step,step)
        ex = (i % 2) * step;
        ey = floor(i / 2) * step;
        dx = (xs[i] - xs[0]) - ex;
        dy = (ys[i] - ys[0]) - ey;
        d  = sqrt(dx * dx + dy * dy);
        if (d > worst)
            worst = d;
    }
    return worst;
}

// Floating-point value of "key" in a JSON fragment, or NaN when absent.
function jsonNum(s, key) {
    marker = "\"" + key + "\"";
    i = indexOf(s, marker);
    if (i < 0)
        return NaN;
    rest = substring(s, i + lengthOf(marker));
    c = indexOf(rest, ":");
    if (c < 0)
        return NaN;
    rest = substring(rest, c + 1);
    e = lengthOf(rest);
    a = indexOf(rest, ",");   if (a >= 0 && a < e) e = a;
    b = indexOf(rest, "}");   if (b >= 0 && b < e) e = b;
    return parseFloat(substring(rest, 0, e));
}

// Integer value of "key" in a JSON fragment, or NaN when absent.
function jsonInt(s, key) {
    marker = "\"" + key + "\"";
    i = indexOf(s, marker);
    if (i < 0)
        return NaN;
    rest = substring(s, i + lengthOf(marker));
    c = indexOf(rest, ":");
    if (c < 0)
        return NaN;
    rest = substring(rest, c + 1);
    e = lengthOf(rest);
    a = indexOf(rest, ",");   if (a >= 0 && a < e) e = a;
    b = indexOf(rest, "}");   if (b >= 0 && b < e) e = b;
    return parseInt(substring(rest, 0, e));
}

// 1 -> A, 26 -> Z, 27 -> AA (the usual convention for >384-well plates).
function rowLetter(n) {
    letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
    if (n < 1)
        return "?";
    if (n <= 26)
        return substring(letters, n - 1, n);
    hi = floor((n - 1) / 26);
    lo = (n - 1) % 26;
    if (hi > 26)
        return "?";
    return substring(letters, hi - 1, hi) + substring(letters, lo, lo + 1);
}
