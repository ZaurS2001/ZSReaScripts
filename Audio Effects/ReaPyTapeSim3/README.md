# Analog Tape Simulator (REAPER Offline Processor)

A highly realistic, procedural analog tape degradation simulator, making your audio sound like it was put through some really bad tape recorder. This tool bridges a custom Python DSP engine with a seamless, native-feeling REAPER Lua interface using ReaImGui. 

It allows you to drag and drop audio files (or grab items directly from your REAPER timeline), process them offline with true-to-life tape wow, flutter, chewing, hiss, and dropouts, and automatically place the newly rendered audio right back into your REAPER session.

---

## 🛠️ Prerequisites

To run this script, your system needs a few standard tools installed:

1. **REAPER & ReaImGui:** 
   * You need the **ReaImGui** extension installed in REAPER.
   * You can download this via [ReaPack](https://reapack.com/). Once ReaPack is installed, go to `Extensions > ReaPack > Browse packages`, search for `ReaImGui`, right-click to install, and hit Apply.
2. **Python 3:** 
   * Ensure Python is installed and added to your system `PATH`.
3. **FFmpeg:** 
   * The Python script uses FFmpeg to handle reading/writing various audio formats (MP3, 32-bit float WAV, etc.). 
   * Download [FFmpeg](https://ffmpeg.org/download.html) and make sure it is added to your Windows/macOS System `PATH` so that Python can access it from the command line.

---

## 📦 Installation (Via ReaPack)

1. In REAPER, go to **Extensions > ReaPack > Import repositories...**
2. Paste the raw URL of the `index.xml` file provided by the developer.
3. Go to **Extensions > ReaPack > Browse packages**, search for `Analog Tape Simulator`, right-click and choose **Install**, then click **Apply** in the bottom right.
4. **⚠️ CRUCIAL FINAL STEP (Installing DSP Dependencies):**
   * ReaPack has downloaded the scripts, but you must install the Python audio libraries.
   * Open REAPER's **Action List** (`?`).
   * Search for `ReaPyTapeSim3`.
   * Right-click the Lua script in the list and select **"Show in Explorer/Finder"**.
   * Open your Command Prompt (Windows) or Terminal (Mac), navigate to that exact folder, and run:
     ```bash
     pip install -r requirements.txt
     ```

## 📦 Installation (Manual / Offline)

If you aren't using ReaPack, you can install it manually:
1. Create a folder in your REAPER Scripts directory (e.g., `REAPER/Scripts/Tape Simulator/`).
2. Place all 4 project files into this exact same folder (`TapeSim3_UI.lua`, `tape_sim3.py`, `requirements.txt`, `README.md`).
3. Open your terminal, navigate to your folder, and run: `pip install -r requirements.txt`
4. In REAPER, go to `Actions > Show action list... > New action... > Load ReaScript...` and select `TapeSim3_UI.lua`.

---

## 🚀 How to Use

Run the script from your REAPER Action List.

### Inside the UI:
* **Inputing Audio:**
  * Click the big browse button to select a file from your computer.
  * **Drag and Drop** an audio file directly from Windows Explorer or REAPER's Media Explorer into the UI.
  * Highlight a media item in your REAPER timeline and click **"Grab Selected Item from REAPER Timeline"**.
* **Tweaking Parameters:**
  * **Tape Age %:** Controls the severity of the degradation. Lower values yield subtle warmth and saturation; higher values introduce severe wow, flutter, tape chewing, and dropouts.
  * **Tape Type:** Choose between standard cassette (Type A) or VHS (Type B - introduces distinct electrical hums, tracking issues, and head-switching noise).
  * **Output Format:** Choose your desired final render format, sample rate, and bit depth/bitrate.
* **Processing:**
  * Click **PROCESS OFFLINE**. A command prompt may briefly flash as Python processes the audio.
  * If you processed a file from outside REAPER, a **new track** will be created with your processed audio.
  * If you processed a clip grabbed from the timeline, the processed audio will be added as a **new active take** directly on top of your original item!

---

## 🐛 Troubleshooting

If the processing fails, the Lua script will pop open the REAPER Console window and print the exact error Python generated. 

* **`No such file or directory`**: The Python script is missing, misnamed, or has a hidden `.txt` extension (Windows users, ensure file extensions are visible!).
* **`ffmpeg is not recognized`**: FFmpeg is not installed or not added to your system environment variables.
* **`ModuleNotFoundError`**: You forgot to run `pip install -r requirements.txt` inside the script's folder.
