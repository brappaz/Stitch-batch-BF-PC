/*
 * Mosaic_Stitched_Wells.ijm   v2.3
 *
 * Builds a plate-shaped mosaic from the stitched well images produced by
 * Batch_Stitch_Plate.ijm (DHM) or by the BF/PC stitching macro. File names are
 * <Letter><Number> optionally followed by "_" and anything else, so both B03.tif
 * and B03_00001_00001.tif are recognised; the label drawn on the tile is always
 * just the well id (B03).
 *
 * Changes
 *   v2.3  32-bit mosaics (DHM) are saved as 16-bit, half the size, and look the
 *         same: the values are mapped linearly onto 0-65535, the display range
 *         follows, and a calibration keeps the original values readable.
 *   v2.2  Output file name can be set (dialog, or 5th argument), and the contrast
 *         mode can be given as 6th argument ("same" or "per well"). A folder called
 *         Brightfield or Phase Contrast gives Mosaic_BF.tif or Mosaic_PC.tif, so
 *         those mosaics no longer overwrite Mosaic_DHM.tif. Mosaic_BF_PC.ijm uses
 *         this to build both in one go. The Log is only cleared when run by hand.
 *         Fixed: 16-bit images (e.g. BF, PC) stopped with "Array expected" when
 *         their range was measured.
 *   v2.1  Output named Mosaic_DHM.tif; colour bar off by default.
 *   v2.0  One display range (colour map) for all wells, so wells can be compared.
 *         The mosaic keeps the original pixel values (e.g. DHM values in 32-bit)
 *         and only its display range is set; an optional colour bar shows the
 *         scale. The range is "auto" (median over the wells of each well's own
 *         auto range) or typed in. Wells much brighter or darker than the plate
 *         are listed in the Log. Choice of LUT. Empty pixels (value 0) are
 *         ignored when measuring a range. The v1 behaviour (each well stretched
 *         on its own) is still available as "Per well".
 *         v1 made B20 of the 2026-09-09 DHM plate look dark: a few very bright
 *         objects in that well pushed its own range up to ~11 instead of ~4.
 *   v1.0  Each well contrast-stretched on its own (2 x B&C "Auto").
 *
 *   - every well with the same letter ends up on the same mosaic row,
 *     every well with the same number on the same mosaic column;
 *   - all images are cropped to a centred square whose side is
 *     min(median width, median height) over the whole set, so slightly
 *     different acquisition sizes do not break the grid;
 *   - the squares are downsampled by the scale factor you enter;
 *   - the well id is burned into the top-left corner of each tile with a
 *     font 1/8 of the tile size;
 *   - a 32-bit mosaic (DHM) is saved as 16-bit with the same look on screen;
 *     its calibration (Analyze > Calibrate) converts back to the 32-bit values,
 *     so the status bar, Measure and B&C show the original values;
 *   - the mosaic is written to the PARENT of the input folder as Mosaic_DHM.tif,
 *     or Mosaic_BF.tif / Mosaic_PC.tif if the input folder is called Brightfield /
 *     Phase Contrast (the name can be changed in the dialog).
 *
 * Wells that are missing from the folder are left black.
 *
 * Install: copy into Fiji.app/plugins/ -> Plugins > Mosaic Stitched Wells
 * Or open it in the Script Editor and press Run.
 *
 * Non-interactive use: pass the folder as the macro argument, optionally with
 * the scale, the display range, the output file name and the contrast mode
 * ("same" or "per well") after "|", e.g.
 *     runMacro("Mosaic_Stitched_Wells.ijm", "D:/data/Registered/stitched_tiles|0.25");
 *     runMacro("Mosaic_Stitched_Wells.ijm", "D:/data/Registered/stitched_tiles|0.25|-0.1|4");
 *     runMacro("Mosaic_Stitched_Wells.ijm", "D:/data/stitched_tiles/Brightfield|0.33|auto|auto|Mosaic_BF.tif|per well");
 */

// ---------------------------------------------------------------- settings --
mosaicName    = "Mosaic_DHM.tif"; // written into the parent of the input folder,
folderNames   = newArray("Brightfield",   "Phase Contrast"); // except for input
folderMosaics = newArray("Mosaic_BF.tif", "Mosaic_PC.tif");  // folders with these names
scale         = 0.33;           // default shown in the dialog (1 = full size)
labelFraction = 0.125;          // label font size as a fraction of the tile size (1/8)
contrastModes = newArray("Same range for all wells", "Per well (each well stretched on its own)");
contrastMode  = contrastModes[0];
rangeMin      = "auto";         // display range of the mosaic, in pixel values,
rangeMax      = "auto";         // or "auto"
saturated     = 0.7;            // auto range: % of the non-empty pixels of a well
                                // left outside its range, half at each end
                                // (0.7 = two clicks on the B&C "Auto" button)
lutName       = "Grays";
colourBar     = false;          // colour bar right of the plate (same range only)
outlierFactor = 1.5;            // wells whose own range is this much wider (or
                                // narrower) than the plate range are listed
save16bit     = true;           // save 32-bit mosaics as 16-bit (same look, half
                                // the size); false keeps them 32-bit
fastMeasure   = true;           // read sizes from the TIFF headers only.
                                // Set to false if "TIFF Virtual Stack..." ever
                                // misbehaves - it then opens each file normally
                                // (correct, just slower).
// -----------------------------------------------------------------------------

// Input: either a macro argument ("path", "path|scale", "path|scale|min|max",
// "path|scale|min|max|name" or "path|scale|min|max|name|contrast"), or asked for.
arg = getArgument();
outName = "";
if (lengthOf(arg) > 0) {
    parts = split(arg, "|");
    inputDir = parts[0];
    if (parts.length > 1) {
        v = parseFloat(parts[1]);
        if (!isNaN(v))
            scale = v;
    }
    if (parts.length > 3) {
        rangeMin = parts[2];
        rangeMax = parts[3];
    }
    if (parts.length > 4)
        outName = parts[4];
    if (parts.length > 5) {
        if (startsWith(toLowerCase(String.trim(parts[5])), "per"))
            contrastMode = contrastModes[1];
        else
            contrastMode = contrastModes[0];
    }
    interactive = false;
} else {
    inputDir = getDirectory("Choose the folder with the stitched well images");
    interactive = true;
}
if (lengthOf(inputDir) == 0)
    exit("No folder selected.");
inputDir = normalizeDir(inputDir);

// Output name: given, or from the input folder's name (BF, PC), or the default.
if (lengthOf(outName) == 0) {
    outName = mosaicName;
    folder  = substring(inputDir, lengthOf(parentOf(inputDir)), lengthOf(inputDir) - 1);
    for (i = 0; i < folderNames.length; i++) {
        if (toLowerCase(folder) == toLowerCase(folderNames[i]))
            outName = folderMosaics[i];
    }
}

// When called from another macro (e.g. Mosaic_BF_PC.ijm), keep what is in the Log.
if (interactive)
    print("\\Clear");
print("Mosaic Stitched Wells v2.3");
print("Input folder: " + inputDir);

// ------------------------------------------------ collect the well images --
list  = getFileList(inputDir);
names = newArray(0);
ids   = newArray(0);
rows  = newArray(0);
cols  = newArray(0);
for (i = 0; i < list.length; i++) {
    name = list[i];
    low  = toLowerCase(name);
    if (endsWith(low, ".tif") || endsWith(low, ".tiff")) {
        base = substring(name, 0, lastIndexOf(name, "."));
        // Accept "B03" and "B03_<anything>", e.g. B03_00001_00001: leading letters,
        // then digits, then either nothing or "_" and whatever follows.
        k = 0;
        while (k < lengthOf(base) && indexOf("0123456789", substring(base, k, k + 1)) < 0)
            k++;
        j = k;
        while (j < lengthOf(base) && indexOf("0123456789", substring(base, j, j + 1)) >= 0)
            j++;
        letters = substring(base, 0, k);
        digits  = substring(base, k, j);
        rest    = substring(base, j);
        if (matches(letters, "[A-Za-z]+") && lengthOf(digits) > 0
                && (lengthOf(rest) == 0 || startsWith(rest, "_"))) {
            r = rowIndex(letters);
            c = parseInt(digits);
            if (r > 0 && !isNaN(c)) {
                wellId = letters + digits;      // the label stays "B03"
                names  = Array.concat(names, name);
                ids    = Array.concat(ids,   wellId);
                rows   = Array.concat(rows,  r);
                cols   = Array.concat(cols,  c);
            }
        }
    }
}
n = names.length;
if (n == 0)
    exit("No <Letter><Number>.tif files found in " + inputDir);

Array.getStatistics(rows, minRow, maxRow, dummy1, dummy2);
Array.getStatistics(cols, minCol, maxCol, dummy1, dummy2);
nRows = maxRow - minRow + 1;
nCols = maxCol - minCol + 1;
print("Well images found: " + n + "   grid " + nRows + " rows x " + nCols + " columns");

// Two files for the same well (e.g. a leftover B03.tif next to B03_00001_00001.tif)
// would silently overwrite each other in the mosaic, so say so.
for (i = 0; i < n; i++) {
    for (j = i + 1; j < n; j++) {
        if (rows[i] == rows[j] && cols[i] == cols[j])
            print("  WARNING: " + names[i] + " and " + names[j]
                  + " are both well " + ids[i] + " - the later one wins");
    }
}

// ----------------------------------------- pass 1: measure every image size --
setBatchMode(true);
widths  = newArray(n);
heights = newArray(n);
bd = 0;
for (i = 0; i < n; i++) {
    showProgress(i + 1, n);
    showStatus("Measuring " + names[i]);
    if (fastMeasure)
        run("TIFF Virtual Stack...", "open=[" + inputDir + names[i] + "]");
    else
        open(inputDir + names[i]);
    widths[i]  = getWidth();
    heights[i] = getHeight();
    if (i == 0)
        bd = bitDepth();
    close();
}
setBatchMode(false);

medW = medianOf(widths);
medH = medianOf(heights);
side = round(minOf(medW, medH));
if (side < 2)
    exit("Median image size is degenerate (" + medW + " x " + medH + ").");
print("Median size: " + medW + " x " + medH + " px  ->  centred square crop of " + side + " px");

// --------------------------------------------------------------- the dialog --
if (interactive) {
    luts = getList("LUTs");
    Dialog.create("Well Mosaic v2.3");
    Dialog.addMessage("Well images: " + n + "   (grid " + nRows + " x " + nCols + ")"
        + "\nMedian size: " + medW + " x " + medH + " px"
        + "\nCentred square crop: " + side + " x " + side + " px"
        + "\nAt scale 1 the mosaic would be " + (nCols * side) + " x " + (nRows * side) + " px");
    Dialog.addNumber("Downsampling scale", scale, 3, 8, "(1 = full size, 0.25 = quarter)");
    Dialog.addString("Output file", outName, 20);
    if (bd != 24) {
        Dialog.addChoice("Contrast", contrastModes, contrastMode);
        Dialog.addString("Display range min", rangeMin, 8);
        Dialog.addToSameRow();
        Dialog.addString("max", rangeMax, 8);
        Dialog.addMessage("Pixel values, or \"auto\": the median over the wells of each well's\n"
            + "own range (" + saturated + " % of its pixels saturated). Used by \"Same range\".");
        Dialog.addChoice("Colour map (LUT)", luts, lutName);
        Dialog.addCheckbox("Colour bar (same range only)", colourBar);
    }
    Dialog.show();
    scale = Dialog.getNumber();
    outName = Dialog.getString();
    if (bd != 24) {
        contrastMode = Dialog.getChoice();
        rangeMin     = Dialog.getString();
        rangeMax     = Dialog.getString();
        lutName      = Dialog.getChoice();
        colourBar    = Dialog.getCheckbox();
    }
}
if (isNaN(scale) || scale <= 0 || scale > 1)
    exit("Scale must be greater than 0 and at most 1 (got " + scale + ").");
outName = String.trim(outName);
if (lengthOf(outName) == 0)
    outName = mosaicName;
if (!endsWith(toLowerCase(outName), ".tif") && !endsWith(toLowerCase(outName), ".tiff"))
    outName = outName + ".tif";
sameRange = (contrastMode == contrastModes[0]) && (bd != 24);
perWell   = (contrastMode == contrastModes[1]) && (bd != 24);
fixedMin  = parseFloat(rangeMin);     // NaN for "auto"
fixedMax  = parseFloat(rangeMax);
if (sameRange && !isNaN(fixedMin) && !isNaN(fixedMax) && fixedMax <= fixedMin)
    exit("Display range max (" + rangeMax + ") must be larger than min (" + rangeMin + ").");

tileSize = round(side * scale);
if (tileSize < 1)
    tileSize = 1;
mosaicW  = nCols * tileSize;
mosaicH  = nRows * tileSize;
fontSize = maxOf(8, round(tileSize * labelFraction));

print("Scale: " + scale + "  ->  tiles of " + tileSize + " px");
outBd = bd;
if (bd == 32 && save16bit)
    outBd = 16;
print("Mosaic: " + mosaicW + " x " + mosaicH + " px, saved as " + outBd + "-bit  (~"
      + d2s(mosaicW * mosaicH * (outBd / 8) / 1048576, 0) + " MB)");
if (sameRange)
    print("Contrast: same range for all wells (min " + rangeMin + ", max " + rangeMax + ")");
else if (perWell)
    print("Contrast: per well (" + saturated + " % saturated)");

// ----------------------------------------------- pass 2: build the mosaic --
if (bd == 8)       typeStr = "8-bit";
else if (bd == 16) typeStr = "16-bit";
else if (bd == 24) typeStr = "RGB";
else               typeStr = "32-bit";

// Value that reads as white once the tiles have been stretched (per-well mode).
if (bd == 16)      fullMax = 65535;
else if (bd == 32) fullMax = 1;
else               fullMax = 255;

setBatchMode(true);
newImage("Mosaic", typeStr + " black", mosaicW, mosaicH, 1);
mosaicId = getImageID();

placed   = newArray(n);     // 1 once the tile has been pasted
wellLo   = newArray(n);     // each well's own auto range (NaN if not measured)
wellHi   = newArray(n);
nPlaced  = 0;
nBad     = 0;
pxUnit   = "";
pxSize   = 0;

for (i = 0; i < n; i++) {
    showProgress(i + 1, n);
    showStatus("Placing " + ids[i]);
    wellLo[i] = NaN;
    wellHi[i] = NaN;

    open(inputDir + names[i]);
    if (bitDepth() != bd) {
        print("  WARNING: " + names[i] + " is " + bitDepth() + "-bit, expected " + bd
              + " - skipped");
        close();
        nBad++;
    } else {
        w = getWidth();
        h = getHeight();
        if (nPlaced == 0) {
            getPixelSize(pxUnit, pw, ph);
            pxSize = pw;
        }

        // centred square crop, padded with zeros if the image is smaller than "side"
        cx = maxOf(0, floor((w - side) / 2));
        cy = maxOf(0, floor((h - side) / 2));
        makeRectangle(cx, cy, minOf(side, w), minOf(side, h));
        run("Crop");
        if (getWidth() != side || getHeight() != side)
            run("Canvas Size...", "width=" + side + " height=" + side + " position=Center zero");

        if (bd != 24) {
            r = wellRange(saturated);
            wellLo[i] = r[0];
            wellHi[i] = r[1];
        }

        // Per-well mode: stretch this well's range to the full range and write
        // it into the pixels (Copy/Paste carries pixel values, not display ranges).
        // Same-range mode keeps the original values.
        if (perWell && !isNaN(wellLo[i]) && wellHi[i] > wellLo[i]) {
            if (bd == 32) {
                // d2s(,-9) keeps full float precision in the options string
                run("Subtract...", "value=" + d2s(wellLo[i], -9));
                run("Divide...",   "value=" + d2s(wellHi[i] - wellLo[i], -9));
                run("Min...", "value=0");
                run("Max...", "value=1");
            } else {
                setMinAndMax(wellLo[i], wellHi[i]);
                run("Apply LUT");
            }
        }

        if (tileSize != side)
            run("Size...", "width=" + tileSize + " height=" + tileSize
                         + " average interpolation=Bilinear");

        run("Select All");
        run("Copy");
        close();

        selectImage(mosaicId);
        makeRectangle((cols[i] - minCol) * tileSize, (rows[i] - minRow) * tileSize,
                      tileSize, tileSize);
        run("Paste");
        run("Select None");

        placed[i] = 1;
        nPlaced++;
    }
}

// --------------------------------------------------------- display range --
selectImage(mosaicId);
run("Select None");
lo = 0;
hi = fullMax;
if (sameRange) {
    lo = medianFinite(wellLo);
    hi = medianFinite(wellHi);
    if (!isNaN(fixedMin))
        lo = fixedMin;
    if (!isNaN(fixedMax))
        hi = fixedMax;
    if (isNaN(lo) || isNaN(hi) || hi <= lo) {
        getMinAndMax(lo, hi);       // nothing measurable: whole mosaic range
        if (hi <= lo)
            hi = lo + 1;
    }
    print("Display range: " + d2s(lo, 4) + " to " + d2s(hi, 4));

    // Wells whose own range is far from the plate's: they look much brighter
    // (or much darker) than their own auto contrast would show them.
    span = hi - lo;
    nOut = 0;
    for (i = 0; i < n; i++) {
        if (placed[i] == 1 && !isNaN(wellHi[i])) {
            own = wellHi[i] - lo;
            if (own > outlierFactor * span || own < span / outlierFactor) {
                if (nOut == 0)
                    print("Wells whose own range differs from the plate's by more than "
                          + outlierFactor + "x (own range " + saturated + " % saturated):");
                if (own > outlierFactor * span)
                    what = "brighter";
                else
                    what = "darker";
                print("  " + ids[i] + ": " + d2s(wellLo[i], 3) + " to " + d2s(wellHi[i], 3)
                      + "  (" + what + " than the plate)");
                nOut++;
            }
        }
    }
    if (nOut == 0)
        print("All wells have a range within " + outlierFactor + "x of the plate's.");
}

// ------------------------------------------------- labels, bar and saving --
if (bd != 24)
    setMinAndMax(lo, hi);
setFont("SansSerif", fontSize, "bold antialiased");
if (bd == 24)
    setColor(255, 255, 255);
else
    setColor(hi);                   // white at the top of the display range

pad = maxOf(2, round(tileSize * 0.03));
for (i = 0; i < n; i++) {
    if (placed[i] == 1)
        drawString(ids[i], (cols[i] - minCol) * tileSize + pad,
                           (rows[i] - minRow) * tileSize + pad + fontSize);
}

if (sameRange && colourBar)
    drawColourBar(lo, hi, mosaicW, mosaicH, tileSize, fontSize);

if (bd != 24) {
    run(lutName);
    setMinAndMax(lo, hi);           // drawing must not shift the display range
}
// 32-bit -> 16-bit with the same look. The values are mapped linearly onto
// 0-65535 and the display range is mapped with them; a calibration maps back.
// The mapped interval is the mosaic's min-max, limited to 7.5 display ranges
// beyond each end, so the displayed range always gets at least 4096 grey
// levels; values beyond the limits are clipped, but they were already
// saturated on screen. Empty pixels (0) all get the same 16-bit level, which
// calibrates back to 0.
if (bd == 32 && save16bit) {
    run("Select None");
    getStatistics(dummy, dummy, vMin, vMax);
    span = hi - lo;
    a = maxOf(vMin, lo - 7.5 * span);
    b = minOf(vMax, hi + 7.5 * span);
    if (b <= a)
        b = a + 1;
    step = (b - a) / 65535;
    if (a < 0 && b > 0) {
        a = -round(-a / step) * step;   // 0 falls on a whole 16-bit level
        b = a + 65535 * step;
    }
    run("Subtract...", "value=" + d2s(a, -9));
    run("Divide...",   "value=" + d2s(step, -9));
    run("Min...", "value=0");
    run("Max...", "value=65535");
    setMinAndMax(0, 65535);
    run("16-bit");
    setMinAndMax((lo - a) / step, (hi - a) / step);  // before calibrating: raw values
    run("Calibrate...", "function=[Straight Line] unit=[32-bit value] text1=[0 65535] text2=["
        + d2s(a, 9) + " " + d2s(b, 9) + "]");      // Calibrate does not read 1.2E3
    note = "";
    if (vMin < a || vMax > b)
        note = " (" + d2s(vMin, 3) + " to " + d2s(vMax, 3) + " in the mosaic: the rest is clipped)";
    print("16-bit: values " + d2s(a, 4) + " to " + d2s(b, 4) + " -> 0 to 65535" + note);
}
if (pxSize > 0 && pxUnit != "pixel" && pxUnit != "pixels")
    setVoxelSize(pxSize * side / tileSize, pxSize * side / tileSize, 1, pxUnit);

parent = parentOf(inputDir);
if (lengthOf(parent) == 0)
    parent = inputDir;
outPath = parent + outName;
saveAs("Tiff", outPath);

setBatchMode("exit and display");
showProgress(1);
showStatus("");
print("Saved " + outPath);
print("=== Finished: " + nPlaced + " tiles placed, " + nBad + " skipped, "
      + (nRows * nCols - nPlaced) + " empty cells ===");

// ------------------------------------------------------------------ helpers --

// Display range of the active image that leaves sat % of its non-empty pixels
// outside, half below and half above, like the B&C "Auto" button. Pixels equal
// to 0 are empty areas (outside the stitched field) and are ignored.
// Returns [lo, hi], or [NaN, NaN] if the image is empty.
function wellRange(sat) {
    b = bitDepth();
    if (b == 32) {
        changeValues(0, 0, NaN);
        nb = 4096;
    } else if (b == 16)
        nb = 65536;
    else
        nb = 256;
    getHistogram(values, counts, nb);
    if (b == 32)
        changeValues(NaN, NaN, 0);
    else
        counts[0] = 0;
    total = 0;
    for (j = 0; j < nb; j++)
        total += counts[j];
    res = newArray(NaN, NaN);
    if (total == 0)
        return res;
    cut = total * sat / 200;
    acc = 0;
    j = 0;
    while (acc + counts[j] <= cut) {
        acc += counts[j];
        j++;
    }
    // 8 and 16-bit: the bin is the pixel value (getHistogram leaves "values"
    // empty for a 65536-bin 16-bit histogram); 32-bit: bin start from "values".
    if (b == 32)
        res[0] = values[j];
    else
        res[0] = j;
    acc = 0;
    j = nb - 1;
    while (acc + counts[j] <= cut) {
        acc += counts[j];
        j--;
    }
    if (b == 32)
        res[1] = values[j] + (values[1] - values[0]);     // top of the bin
    else
        res[1] = j;
    return res;
}

// Enlarges the active image to the right and draws a vertical colour bar from
// lo (bottom) to hi (top) with 5 labelled ticks, in pixel values, so it follows
// whatever LUT is applied afterwards.
function drawColourBar(lo, hi, plateW, plateH, tile, font) {
    barFont = maxOf(8, round(font * 0.6));
    barW    = maxOf(4, round(tile * 0.15));
    barH    = minOf(plateH - 2 * barFont, 4 * tile);
    gap     = maxOf(2, round(barFont * 0.4));
    x0      = plateW + 2 * gap;
    y0      = barFont;
    dec     = maxOf(0, 2 - floor(log(hi - lo) / log(10)));
    setFont("SansSerif", barFont, "antialiased");
    textW = 0;
    for (k = 0; k <= 4; k++)
        textW = maxOf(textW, getStringWidth(d2s(lo + k * (hi - lo) / 4, dec)));
    run("Canvas Size...", "width=" + (x0 + barW + gap + textW + 2 * gap)
        + " height=" + plateH + " position=Top-Left zero");
    setMinAndMax(lo, hi);
    for (y = 0; y < barH; y++) {
        setColor(hi - (hi - lo) * y / (barH - 1));
        fillRect(x0, y0 + y, barW, 1);
    }
    setColor(hi);
    drawRect(x0 - 1, y0 - 1, barW + 2, barH + 2);
    for (k = 0; k <= 4; k++) {
        y = y0 + round((barH - 1) * (1 - k / 4));
        drawLine(x0 + barW, y, x0 + barW + gap - 1, y);
        drawString(d2s(lo + k * (hi - lo) / 4, dec), x0 + barW + gap, y + round(barFont / 2));
    }
}

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
    d = substring(d, 0, lengthOf(d) - 1);
    i = lastIndexOf(d, "/");
    if (i < 1)
        return "";
    return substring(d, 0, i + 1);
}

// "A" -> 1, "Z" -> 26, "AA" -> 27 (bijective base 26), or -1 if not a letter run.
function rowIndex(letters) {
    letters = toUpperCase(letters);
    v = 0;
    for (i = 0; i < lengthOf(letters); i++) {
        p = indexOf("ABCDEFGHIJKLMNOPQRSTUVWXYZ", substring(letters, i, i + 1));
        if (p < 0)
            return -1;
        v = v * 26 + p + 1;
    }
    return v;
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

// Median of the non-NaN entries of a numeric array, NaN if there are none.
function medianFinite(a) {
    b = newArray(0);
    for (i = 0; i < a.length; i++) {
        if (!isNaN(a[i]))
            b = Array.concat(b, a[i]);
    }
    return medianOf(b);
}
