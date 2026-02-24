import argparse
import numpy as np
import scipy.signal as sig
from scipy.interpolate import CubicSpline
import soundfile as sf
import sys
import subprocess
import tempfile
import os

# ==========================================
# DSP Helper Functions
# ==========================================

def apply_lowpass(data, cutoff, sr, order=2):
    nyq = 0.5 * sr
    normal_cutoff = max(min(cutoff / nyq, 0.99), 0.0001)
    sos = sig.butter(order, normal_cutoff, btype='low', analog=False, output='sos')
    return sig.sosfilt(sos, data, axis=0).astype(np.float32)

def apply_highpass(data, cutoff, sr, order=2):
    nyq = 0.5 * sr
    normal_cutoff = max(min(cutoff / nyq, 0.99), 0.0001)
    sos = sig.butter(order, normal_cutoff, btype='high', analog=False, output='sos')
    return sig.sosfilt(sos, data, axis=0).astype(np.float32)

def generate_spline_lfo(length, max_freq, sr):
    duration_sec = length / sr
    num_points = max(int(duration_sec * max_freq * 2.0), 5)
    y = np.random.randn(num_points)
    x_old = np.linspace(0, length, num_points)
    x_new = np.arange(length)
    cs = CubicSpline(x_old, y)
    lfo = cs(x_new).astype(np.float32)
    return lfo / (np.max(np.abs(lfo)) + 1e-8)

def generate_random_pulses(length, sr, average_interval_sec, width_sec):
    env = np.zeros(length, dtype=np.float32)
    if average_interval_sec <= 0: return env
    num_pulses = int((length / sr) / average_interval_sec)
    if num_pulses == 0 and np.random.rand() < ((length / sr) / average_interval_sec):
        num_pulses = 1
    pulse_width_samples = int(width_sec * sr)
    for _ in range(num_pulses):
        idx = np.random.randint(0, max(1, length - pulse_width_samples))
        env[idx:idx+pulse_width_samples] = 1.0
    env = apply_lowpass(env, 2.0, sr, order=2)
    env_max = np.max(env)
    if env_max > 0:
        env /= env_max
    return env

# ==========================================
# Main DSP Processing Class
# ==========================================

def process_tape_sim(input_file, output_file, age_pct, tape_type, out_format, samplerate, bitdepth, bitrate):
    print(f"Loading and decoding audio file: {input_file} ...")
    
    # Use FFMPEG to decode input audio to a temporary 32-bit float WAV
    temp_in = tempfile.NamedTemporaryFile(suffix='.wav', delete=False).name
    try:
        subprocess.run(['ffmpeg', '-y', '-i', input_file, '-c:a', 'pcm_f32le', temp_in], 
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception as e:
        print(f"Error decoding with ffmpeg: {e}")
        sys.exit(1)

    audio, sr = sf.read(temp_in, dtype='float32')
    if audio.ndim == 1:
        audio = audio.reshape(-1, 1)
        
    length, channels = audio.shape
    A = np.clip(age_pct / 100.0, 0.0, 1.0)
    is_vhs = (tape_type.upper() == 'B')

    print(f"Applying Analog Saturation and Base EQ (Age: {age_pct}%) ...")
    drive = 1.0 + A * 3.0
    audio = np.tanh(audio * drive) 
    audio = np.clip(audio, -1.0, drive/1.5)
    cutoff_lp = max(16000 - A * 10000, 1000)
    cutoff_hp = 30 + A * 40
    audio = apply_lowpass(audio, cutoff_lp, sr, order=2)
    audio = apply_highpass(audio, cutoff_hp, sr, order=2)

    print("Calculating Tape Mechanisms and Anomalies...")
    if A > 0.01:
        chew_env = generate_random_pulses(length, sr, average_interval_sec=35 - A*25, width_sec=1.5 + A*1.5)
        tracking_env = generate_random_pulses(length, sr, 20 - A*15, 3.0) if is_vhs else np.zeros(length, dtype=np.float32)
    else:
        chew_env = np.zeros(length, dtype=np.float32)
        tracking_env = np.zeros(length, dtype=np.float32)

    print("Modulating Time-Warp (Wow, Flutter, Azimuth, Pitch-Drops)...")
    wow_freq = np.random.uniform(0.5, 2.0)
    flutter_freq = np.random.uniform(10.0, 25.0)
    
    for ch in range(channels):
        t_idx = np.arange(length, dtype=np.float32)
        w_lfo = np.sin(2 * np.pi * wow_freq * t_idx / sr) * (A * 0.003 * sr)
        f_lfo = np.sin(2 * np.pi * flutter_freq * t_idx / sr) * (A * 0.0005 * sr)
        az_lfo = generate_spline_lfo(length, 0.5, sr) * (A * 0.001 * sr) if channels > 1 else 0
        chew_delay = chew_env * (A * 0.08 * sr) 
        tracking_delay = tracking_env * (A * 0.02 * sr) if is_vhs else 0
        
        total_delay = w_lfo + f_lfo + az_lfo + chew_delay + tracking_delay
        t_read = t_idx - total_delay
        t_read = np.clip(t_read, 0, length - 1)
        warped = np.interp(t_read, t_idx, audio[:, ch]).astype(np.float32)
        
        if A > 0.01:
            t_read2 = t_idx - total_delay * 0.8 - (0.015 * sr)
            t_read2 = np.clip(t_read2, 0, length - 1)
            tap2 = np.interp(t_read2, t_idx, audio[:, ch]).astype(np.float32)
            blend = np.clip(chew_env + tracking_env, 0, 1) * 0.5
            warped = warped * (1 - blend) + tap2 * blend
            
        audio[:, ch] = warped

    print("Mixing Analog Tape Hiss...")
    hiss_base = np.random.randn(length, channels).astype(np.float32)
    b, a = [1.0], [1.0, -0.99]
    hiss = sig.lfilter(b, a, hiss_base, axis=0).astype(np.float32)
    hiss -= np.mean(hiss, axis=0)
    hiss /= (np.max(np.abs(hiss), axis=0) + 1e-8)
    
    if is_vhs:
        hiss = apply_lowpass(hiss, 6000, sr)
        hiss_mod = generate_spline_lfo(length, 2.0, sr).reshape(-1, 1)
        hiss *= (1.0 + hiss_mod * 0.4 * A)
        hiss_level = 0.005 + A * 0.04
    else:
        hiss += np.random.randn(length, channels).astype(np.float32) * 0.05
        hiss = apply_lowpass(hiss, 12000, sr)
        hiss_level = 0.002 + A * 0.03
    audio += hiss * hiss_level

    print("Simulating Tape Head Separation & Dropouts...")
    if A > 0.01:
        dropout_env = generate_random_pulses(length, sr, average_interval_sec=15 - A*10, width_sec=0.2 + A*0.5)
        dropout_env = dropout_env.reshape(-1, 1)
        muffled = apply_lowpass(audio, max(300, 1000 - A*700), sr)
        audio = audio * (1.0 - dropout_env * (A * 0.95))
        audio = audio * (1.0 - dropout_env) + muffled * dropout_env

    if is_vhs:
        print("Injecting VHS Head Switching & Electrical Hum...")
        hum_freq = float(np.random.choice([50.0, 60.0]))
        t_idx = np.arange(length, dtype=np.float32).reshape(-1, 1)
        hum = np.sin(2 * np.pi * hum_freq * t_idx / sr)
        hum += 0.5 * np.sin(2 * np.pi * (hum_freq*2) * t_idx / sr)
        hum += 0.25 * np.sin(2 * np.pi * (hum_freq*3) * t_idx / sr)
        
        pulse_freq = hum_freq / 2.0
        pulse = sig.sawtooth(2 * np.pi * pulse_freq * t_idx / sr)
        pulse = np.clip(pulse, 0.8, 1.0) - 0.8
        hum_signal = (hum * 0.5 + pulse * 5.0) * (0.002 + A * 0.015)
        
        if channels > 1:
            hum_signal = np.repeat(hum_signal, channels, axis=1)
        audio += hum_signal

    print("Normalizing and finalizing format...")
    audio = np.tanh(audio)
    
    temp_out = tempfile.NamedTemporaryFile(suffix='.wav', delete=False).name
    sf.write(temp_out, audio, sr, subtype='PCM_16')

    # FFMPEG Encoding Pass
    cmd = ['ffmpeg', '-y', '-i', temp_out]
    if samplerate:
        cmd.extend(['-ar', str(samplerate)])
        
    if out_format.lower() == 'mp3':
        cmd.extend(['-codec:a', 'libmp3lame'])
        if bitrate: cmd.extend(['-b:a', bitrate])
    else:
        cmd.extend(['-codec:a', 'pcm_s16le']) 
        if bitdepth == '24': cmd[-1] = 'pcm_s24le'
        elif bitdepth == '32': cmd[-1] = 'pcm_f32le'
            
    cmd.append(output_file)
    
    try:
        subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception as e:
        print(f"Error encoding with ffmpeg: {e}")
    finally:
        os.remove(temp_in)
        os.remove(temp_out)
        
    print(f"Success! Saved to: {output_file}")


# ==========================================
# CLI Arguments Parser
# ==========================================

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Procedural Analog Tape Simulator")
    parser.add_argument('-i', '--input', required=True)
    parser.add_argument('-o', '--output', required=True)
    parser.add_argument('-a', '--age', type=float, default=50.0)
    parser.add_argument('-t', '--type', choices=['A', 'B'], default='A')
    parser.add_argument('--out-format', choices=['wav', 'mp3'], default='wav')
    parser.add_argument('--samplerate', type=int, default=44100)
    parser.add_argument('--bitdepth', choices=['16', '24', '32'], default='24')
    parser.add_argument('--bitrate', default='320k')
    
    args = parser.parse_args()
    
    try:
        process_tape_sim(args.input, args.output, args.age, args.type, 
                         args.out_format, args.samplerate, args.bitdepth, args.bitrate)
    except Exception as e:
        print(f"\n[!] An error occurred during processing: {e}")
        sys.exit(1)