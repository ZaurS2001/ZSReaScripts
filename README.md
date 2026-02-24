# ZSReaScripts

A collection of custom REAPER scripts to enhance your audio production workflow. This repository serves as a ReaPack repository, allowing for easy installation and updates of the included scripts directly within REAPER.

## 📦 Installation (Via ReaPack)

1.  In REAPER, go to **Extensions > ReaPack > Import repositories...**
2.  Paste the raw URL of the `index.xml` file, located in the root of this GitHub repository.
3.  Go to **Extensions > ReaPack > Browse packages**, search for the desired script, right-click and choose **Install**, then click **Apply** in the bottom right.

### Individual Script Dependencies:

Some scripts may require additional dependencies, such as Python, FFmpeg, or specific Python packages. Refer to the individual script's documentation (typically included as a `README.md` within its subfolder) for detailed installation instructions.

---

## 📜 Included Scripts

The following scripts are currently available in this ReaPack repository:

### [ReaPyTapeSim3](./Audio%20Effects/ReaPyTapeSim3/README.md)

A highly realistic, procedural analog tape degradation simulator that bridges a custom Python DSP engine with a seamless REAPER Lua interface. This script requires Python, FFmpeg, and the `numpy`, `scipy`, and `soundfile` Python packages. Please refer to its dedicated `README.md` file for detailed installation and usage instructions.

---

## 🤝 Contributing

Contributions to this script collection are welcome! If you have a REAPER script you'd like to share, please follow these steps:

1.  Fork this repository.
2.  Create a new folder within the `Audio Effects` or `Utilities` category (or create a new category if appropriate).
3.  Place your script files (including a `README.md` with installation instructions and usage guidelines) inside the new folder.
4.  Ensure your main Lua script includes the necessary ReaPack metadata tags (`@description`, `@author`, `@version`, `@provides`, `@about`).
5.  Submit a pull request.

---

## ⚠️ Important Notes

*   This repository is automatically indexed by ReaPack. Any changes to the script files will be reflected in the ReaPack repository after a short delay (usually within a few minutes).
*   Please report any issues or suggestions in the [Issues](https://github.com/YourUsername/ZSReaScripts/issues) section of this repository.
*   All scripts are provided as-is, without any warranty. Use them at your own risk.

---

## 🧑‍💻 Author

[ZaurS2001 - Zaur Suleimanov]

---
