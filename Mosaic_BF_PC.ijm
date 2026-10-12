/*
 * Mosaic_BF_PC.ijm   v1.0
 *
 * Plate mosaics of the Brightfield and Phase Contrast images that
 * Crop_BF-PC_to_DHM.ijm cropped to the DHM field of view, built like
 * Mosaic_DHM.tif: same grid, tile size and labels. Each BF/PC image has the size
 * of its DHM image, so at the same scale the three mosaics overlay pixel for pixel.
 *
 * Contrast is set per well by default, unlike the DHM mosaic. BF/PC values are
 * not comparable between wells: wells cropped from the stitched fld 1-4 images
 * were stretched to the full 16-bit range by the stitching macro, while wells
 * cropped from fld 5 keep the raw camera values. With one range for all wells
 * the fld 5 wells look flat and grey (79 of 85 on the 2026-09-09 plate).
 *
 * Choose the folder that holds the "Brightfield" and "Phase Contrast" folders
 * (e.g. Registered/stitched_tiles, next to the DHM folder and Mosaic_DHM.tif).
 * Mosaic_BF.tif and Mosaic_PC.tif are written into that folder.
 *
 * The mosaics are made by Mosaic_Stitched_Wells.ijm (v2.2 or later), which must
 * be in Fiji.app/macros/. At scale 0.33 a 280-well plate gives two mosaics of
 * about 160 MB each (16-bit).
 *
 * Install: copy into Fiji.app/plugins/ -> Plugins > Mosaic BF PC
 * Or open it in the Script Editor and press Run.
 *
 * Non-interactive use: pass the folder, optionally with the scale and the
 * contrast ("per well" or "same") after "|":
 *     runMacro("Mosaic_BF_PC.ijm", "D:/data/Registered/stitched_tiles|0.33");
 *     runMacro("Mosaic_BF_PC.ijm", "D:/data/Registered/stitched_tiles|0.33|same");
 */

// ---------------------------------------------------------------- settings --
scale       = 0.33;                         // as Mosaic_DHM.tif
subFolders  = newArray("Brightfield",   "Phase Contrast");
outNames    = newArray("Mosaic_BF.tif", "Mosaic_PC.tif");
contrasts   = newArray("Per well", "Same range for all wells");
contrast    = contrasts[0];
mosaicMacro = "Mosaic_Stitched_Wells.ijm";
// -----------------------------------------------------------------------------

arg = getArgument();
if (lengthOf(arg) > 0) {
    parts = split(arg, "|");
    dir = parts[0];
    if (parts.length > 1) {
        v = parseFloat(parts[1]);
        if (!isNaN(v))
            scale = v;
    }
    if (parts.length > 2) {
        if (startsWith(toLowerCase(String.trim(parts[2])), "per"))
            contrast = contrasts[0];
        else
            contrast = contrasts[1];
    }
    interactive = false;
} else {
    dir = getDirectory("Choose the folder with the Brightfield and Phase Contrast folders");
    interactive = true;
}
if (lengthOf(dir) == 0)
    exit("No folder selected.");
dir = replace(dir, "\\\\", "/");
if (!endsWith(dir, "/"))
    dir = dir + "/";

// If the Brightfield or Phase Contrast folder itself was chosen, go up one level.
for (k = 0; k < subFolders.length; k++) {
    if (endsWith(toLowerCase(dir), "/" + toLowerCase(subFolders[k]) + "/")) {
        up  = substring(dir, 0, lengthOf(dir) - 1);
        dir = substring(up, 0, lastIndexOf(up, "/") + 1);
    }
}

if (!File.exists(getDirectory("macros") + mosaicMacro))
    exit(mosaicMacro + " was not found in " + getDirectory("macros")
         + "\nIt builds the mosaics: copy it there.");

use    = newArray(subFolders.length);
nFound = 0;
for (k = 0; k < subFolders.length; k++) {
    use[k] = File.isDirectory(dir + subFolders[k]);
    nFound += use[k];
}
if (nFound == 0)
    exit("No Brightfield or Phase Contrast folder in\n" + dir);

if (interactive) {
    Dialog.create("BF and PC mosaics v1.0");
    Dialog.addMessage("Folder: " + dir);
    for (k = 0; k < subFolders.length; k++) {
        if (use[k])
            Dialog.addCheckbox(subFolders[k] + "  ->  " + outNames[k], true);
        else
            Dialog.addMessage(subFolders[k] + ": no such folder");
    }
    Dialog.addNumber("Downsampling scale", scale, 3, 8, "(0.33 as Mosaic_DHM.tif)");
    Dialog.addChoice("Contrast", contrasts, contrast);
    Dialog.addMessage("Per well: BF/PC values differ between wells cropped from fld 5\n"
        + "(raw) and from the stitched fld 1-4 images (already stretched).");
    Dialog.show();
    for (k = 0; k < subFolders.length; k++) {
        if (use[k])
            use[k] = Dialog.getCheckbox();
    }
    scale    = Dialog.getNumber();
    contrast = Dialog.getChoice();
    print("\\Clear");
}

print("Mosaic BF PC v1.0");
print("Folder: " + dir);
print("Contrast: " + contrast);
if (contrast == contrasts[0])
    mode = "per well";
else
    mode = "same";
nFailed = 0;
for (k = 0; k < subFolders.length; k++) {
    if (use[k]) {
        print("");
        print("===== " + subFolders[k] + "  ->  " + outNames[k]);
        ret = runMacro(mosaicMacro, dir + subFolders[k] + "|" + scale + "|auto|auto|" + outNames[k] + "|" + mode);
        if (ret == "[aborted]") {
            print("  ERROR: " + mosaicMacro + " stopped before saving " + outNames[k]
                  + ". Run it on the " + subFolders[k] + " folder to see why.");
            nFailed++;
        }
    }
}
print("");
if (nFailed > 0)
    print("=== Mosaic BF PC finished with " + nFailed + " error(s) ===");
else
    print("=== Mosaic BF PC finished ===");
