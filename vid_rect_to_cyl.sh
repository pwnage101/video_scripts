#!/bin/bash
#
# Example usage:
# vid_rect_to_cyl.sh 24 input.MOV output.MOV

FOCAL_LENGTH=$1
INPUT=$2
OUTPUT=$3

if [[ "${OUTPUT##*.}" != "mkv" ]]; then
    echo "ERROR: output container must be Matroska (.mkv)."
    exit 1
fi

if [[ "${FOCAL_LENGTH}" -lt 34 ]]; then
    echo "ERROR: focal length corrections below 34 will produce vignetting with the hard-coded output aspect of 1.85."
    exit 1
fi

# Calculate the horizontal field of view based on full-frame (35mm) focal
# length given.
HFOV=$(printf "%0.1f\n" $(echo "2 * a(36 / (2 * ${FOCAL_LENGTH})) * 180/(4*a(1))" | bc -l))

# We'll need this to reconstruct the output video from individual frames.
FRAMERATE=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 ${INPUT})

# Retain the original frame width.
WIDTH=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of default=noprint_wrappers=1:nokey=1 ${INPUT})

# Target a specific aspect ratio to determine height.
ASPECT=1.85
HEIGHT=$(printf "%.0f" $(echo "${WIDTH} / ${ASPECT}" | bc -l))

# Make sure the height is still divisible by two so that, e.g., 4:2:0 chroma
# subsampling is still physically possible.
if [[ $(( $HEIGHT % 2 )) -ne 0 ]]; then
    HEIGHT=$(( HEIGHT - 1 ))
fi

tmpdir="${OUTPUT}_tmp"
prefix="${OUTPUT%.*}"

if [[ ! -d "${tmpdir}" ]]; then
    mkdir ${tmpdir}
else
    echo "The tmpdir already exists, not recreating."
fi

# Write the source video frames, in png files with 16-bit per channel depth.
# The conversation from YUV->RGB->RGB->YUV is not lossless, so even for 8-bit
# source video using a 16-bit intermediate may help prevent rounding errors or
# banding.
ffmpeg -i ${INPUT} -pix_fmt rgb48be "${tmpdir}/${prefix}_%08d_input.png"

# Helper function to generate the remapped frame.
img_rect_to_cyl() {
    WIDTH=$1
    HEIGHT=$2
    HFOV=$3
    IN_FRAME=$4
    OUT_FRAME="${IN_FRAME%_input.png}_output.png"
    SCRIPT=$(cat <<EOF
p f1 v$HFOV nPNG w$WIDTH h$HEIGHT
o f0 r0 p0 y0 v$HFOV n"$(readlink -f ${IN_FRAME})"
*
EOF
    )
    echo "$SCRIPT"
    nona -o "$OUT_FRAME" <(echo "$SCRIPT") && \
      rm ${IN_FRAME}
}

export -f img_rect_to_cyl
parallel_args=$(find ${tmpdir} | grep "${prefix}"'_[0-9]*_input.png')
echo "$parallel_args" | parallel -v img_rect_to_cyl "$WIDTH" "$HEIGHT" "$HFOV"

echo "Encoding the output file..."
ffmpeg \
  -r "${FRAMERATE}" -f image2 -i "${tmpdir}/${prefix}"'_%08d_output.png' \
  -i "${INPUT}" \
  -c:v prores_ks -pix_fmt yuv422p10le -profile:v 1 -map 0:v:0 \
  -c:a copy -map 1:a \
  ${OUTPUT}

encode_status=$?
if [[ "$encode_status" -eq 0 ]]; then
    echo "Examine the following output file, then press enter to commence cleanup of intermediate files."
    readlink -f "${OUTPUT}"
    read
    echo "Deleting all intermediate files..."
    rm -r "${tmpdir}"
fi
