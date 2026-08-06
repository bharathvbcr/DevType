import os
import sys
import cv2
import numpy as np

src_path = "/Users/bharath/.gemini/antigravity/brain/54f235f0-a92f-490a-a3f6-c4f67b825399/devtype_3d_logo_1785005422235.jpg"
if not os.path.exists(src_path):
    src_path = "Resources/AppIcon.png"

print(f"Reading image from: {src_path}")
img = cv2.imread(src_path, cv2.IMREAD_COLOR)
if img is None:
    print("Error: Could not load image")
    sys.exit(1)

h, w, _ = img.shape
print(f"Image shape: {h}x{w}")

# Method 1: Remove background outside the 3D D logo emblem (Emblem Only)
# Convert to LAB and Grayscale
gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
hsv = cv2.cvtColor(img, cv2.COLOR_BGR2HSV)

# Sample dark background color from corners
corners = np.vstack([img[0:40, 0:40], img[0:40, w-40:w], img[h-40:h, 0:40], img[h-40:h, w-40:w]])
bg_color = np.median(corners, axis=(0, 1))
print(f"Sampled background BGR color: {bg_color}")

# Calculate color distance to background
diff = img.astype(float) - bg_color
dist = np.sqrt(np.sum(diff ** 2, axis=2))

# Threshold to isolate the 3D object from dark background
# GrabCut for high precision edge refinement around 3D logo
mask = np.zeros((h, w), np.uint8)
bgdModel = np.zeros((1, 65), np.float64)
fgdModel = np.zeros((1, 65), np.float64)

# Define bounding box around central 3D emblem (margin of 15% from edges)
margin_h = int(h * 0.16)
margin_w = int(w * 0.16)
rect = (margin_w, margin_h, w - 2 * margin_w, h - 2 * margin_h)

cv2.grabCut(img, mask, rect, bgdModel, fgdModel, 7, cv2.GC_INIT_WITH_RECT)
mask2 = np.where((mask == 2) | (mask == 0), 0, 1).astype(uint8)

# Enhance mask with thresholding on metallic & red highlights so light/reflections are fully preserved
dist_mask = (dist > 35).astype(np.uint8)
combined_mask = cv2.bitwise_or(mask2, dist_mask)

# Find largest contour (the 3D emblem)
contours, _ = cv2.findContours(combined_mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
if contours:
    c = max(contours, key=cv2.contourArea)
    clean_mask = np.zeros((h, w), np.uint8)
    cv2.drawContours(clean_mask, [c], -1, 255, thickness=cv2.FILLED)

    # Feather edge with Gaussian blur for smooth anti-aliasing
    alpha = cv2.GaussianBlur(clean_mask, (7, 7), 0)
else:
    alpha = (combined_mask * 255).astype(np.uint8)
    alpha = cv2.GaussianBlur(alpha, (5, 5), 0)

# Create 4-channel RGBA image with transparent background
b, g, r = cv2.split(img)
rgba = cv2.merge([b, g, r, alpha])

out_png = "Resources/AppIcon_transparent.png"
cv2.imwrite(out_png, rgba)
print(f"Saved background-removed transparent logo to: {out_png}")

# Also update Resources/AppIcon.png and Resources/StatusIcon.png
cv2.imwrite("Resources/AppIcon.png", rgba)

# Create crisp status bar transparent icon
status_size = (36, 36)
status_icon = cv2.resize(rgba, status_size, interpolation=cv2.INTER_AREA)
cv2.imwrite("Resources/StatusIcon.png", status_icon)

print("OpenCV background removal finished successfully!")
