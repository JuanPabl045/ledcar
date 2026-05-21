# 🚗 LEDCar - Smart Car Interior Lighting System

![Flutter](https://img.shields.io/badge/Flutter-02569B?style=flat-square&logo=flutter&logoColor=white)
![ESP32](https://img.shields.io/badge/ESP32-000000?style=flat-square&logo=espressif&logoColor=white)
![Python](https://img.shields.io/badge/Python-3776AB?style=flat-square&logo=python&logoColor=white)
![TensorFlow](https://img.shields.io/badge/TensorFlowLite-FF6F00?style=flat-square&logo=tensorflow&logoColor=white)
![Spotify](https://img.shields.io/badge/Spotify-1ED760?style=flat-square&logo=spotify&logoColor=white)

LEDCar is an advanced, AI-powered smart lighting system designed for car interiors. It goes beyond simple sound-reactive lights by using Machine Learning and Digital Signal Processing (DSP) to understand the music you are listening to, synchronizing LED strips perfectly with beats, drops, and the emotional mood of the song.

## ✨ Key Features

*   **🧠 AI Emotion Recognition:** Uses a highly optimized Convolutional Neural Network (CNN) built in TensorFlow Lite (only 45 KB!) to classify the current track into 4 emotions (*Happy, Sad, Energetic, Calm*). This automatically drives the base ambient color of the car.
*   **🎵 Real-Time Audio DSP:** 
    *   **Beat Detection:** Extracts BPM in real-time to control LED pulsing speed with ~20ms latency.
    *   **Onset Detection:** Detects musical peaks (like drum hits or bass drops) to trigger dynamic LED flashes based on audio intensity.
*   **📱 Mobile App Control:** A cross-platform Flutter application that acts as the control hub.
*   **🎧 Spotify & Last.fm Integration:** Seamlessly connects to streaming APIs to fetch metadata and track information on the fly.
*   **🔌 ESP32 Hardware Integration:** Low-latency communication with an ESP32 microcontroller to drive addressable RGB LED strips perfectly in sync.

## 🏗️ System Architecture

1.  **Control Hub (Flutter):** The mobile app interfaces with the user, handles Spotify/Last.fm API authentication, and streams audio metadata.
2.  **Audio Processing (TFLite / DSP):** Python-trained ML models and DSP algorithms run efficiently on the edge to analyze spectral flux and audio energy.
3.  **Hardware Driver (ESP32):** Receives the processed lighting commands (color, flash intensity, pulse rate) and physically controls the LEDs.

### System Architecture Flow

[![System Architecture Flow](https://github.com/user-attachments/assets/2b81f78f-5a3c-4ee3-b0b5-4641fecb855f)](https://github.com/user-attachments/assets/2b81f78f-5a3c-4ee3-b0b5-4641fecb855f)
<sub>Haz clic en la imagen para verla completa, hacer zoom y desplazarla con el visor de imágenes del navegador.</sub>

## 🚀 Getting Started

*(Note: Add specific instructions here as the project evolves)*

### Prerequisites
*   Flutter SDK
*   Python 3.x (for tweaking ML models)
*   ESP32 Microcontroller & Addressable LEDs (e.g., WS2812B)
*   Spotify Developer Account (for API keys)

### Installation
1. Clone the repository:
   ```bash
   git clone https://github.com/JuanPabl045/ledcar.git
