# tape_sim3.py

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

def process_tape_sim(args):
    print(f"Loading and decoding audio file: {args.input} ...")
    
    # Use FFMPEG to decode input audio to a temporary 32-bit float WAV
    temp_in = tempfile.NamedTemporaryFile(suffix='.wav', delete=False).name
    try:
        subprocess.run(['ffmpeg', '-y', '-i', args.input, '-c:a', 'pcm_f32le', temp_in], 
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception as e:
        print(f"Error decoding with ffmpeg: {e}")
        sys.exit(1)

    audio, sr = sf.read(temp_in, dtype='float32')
    if audio.ndim == 1:
        audio = audio.reshape(-1, 1)
        
    length, channels = audio.shape
    is_vhs = (args.type.upper() == 'B')
    is_dropouts = (args.dropouts == 1)

    # 1. SATURATION & BASE EQ
    print(f"Applying Analog Saturation (Amount: {args.sat_amt}%) ...")
    S = np.clip(args.sat_amt / 100.0, 0.0, 1.0)
    drive = 1.0 + S * 5.0
    audio = np.tanh(audio * drive) 
    audio = np.clip(audio, -1.0, 1.0)
    
    # Tape inherent base EQ
    audio = apply_lowpass(audio, max(18000 - S * 8000, 1000), sr, order=2)
    audio = apply_highpass(audio, 20 + S * 40, sr, order=2)

    # 2. ANOMALIES & DROPOUTS
    print("Calculating Tape Mechanisms and Dropouts...")
    if is_dropouts:
        prob = np.clip(args.drop_prob / 100.0, 0.0, 1.0)
        # 0% = average 50 secs apart. 100% = average 0.5 sec apart
        avg_interval = 50.0 - (prob * 49.5)
        
        dropout_env = generate_random_pulses(length, sr, average_interval_sec=avg_interval, width_sec=0.2 + prob*0.5)
        chew_env = generate_random_pulses(length, sr, average_interval_sec=avg_interval * 1.5, width_sec=1.0 + prob*1.0)
        tracking_env = generate_random_pulses(length, sr, avg_interval * 1.2, 3.0) if is_vhs else np.zeros(length, dtype=np.float32)
    else:
        dropout_env = np.zeros(length, dtype=np.float32)
        chew_env = np.zeros(length, dtype=np.float32)
        tracking_env = np.zeros(length, dtype=np.float32)

    # 3. WOW AND FLUTTER
    print("Modulating Time-Warp (Wow, Flutter, Azimuth)...")
    
    t_idx = np.arange(length, dtype=np.float32)

    # Wow LFO Generation
    w_base = args.wow_rate
    w_var_amt = args.wow_var / 100.0
    w_depth_smp = (args.wow_depth / 100.0) * 0.005 * sr
    
    if w_var_amt > 0:
        w_freq_mod = w_base * (1.0 + w_var_amt * generate_spline_lfo(length, max(0.1, w_base * 0.5), sr))
        w_phase = np.cumsum(w_freq_mod) / sr
    else:
        w_phase = w_base * t_idx / sr
    w_lfo = np.sin(2 * np.pi * w_phase) * w_depth_smp

    # Flutter LFO Generation
    f_base = args.flutter_rate
    f_var_amt = args.flutter_var / 100.0
    f_depth_smp = (args.flutter_depth / 100.0) * 0.001 * sr
    
    if f_var_amt > 0:
        f_freq_mod = f_base * (1.0 + f_var_amt * generate_spline_lfo(length, max(0.5, f_base * 0.5), sr))
        f_phase = np.cumsum(f_freq_mod) / sr
    else:
        f_phase = f_base * t_idx / sr
    f_lfo = np.sin(2 * np.pi * f_phase) * f_depth_smp

    for ch in range(channels):
        az_lfo = generate_spline_lfo(length, 0.5, sr) * ((args.drop_delay_drift/100.0) * 0.001 * sr) if channels > 1 else 0
        
        # Delay Drift Depth calculation
        drift_smp = (args.drop_delay_drift / 100.0) * 0.1 * sr
        chew_delay = chew_env * drift_smp 
        tracking_delay = tracking_env * (S * 0.02 * sr) if is_vhs else 0
        
        total_delay = w_lfo + f_lfo + az_lfo + chew_delay + tracking_delay
        t_read = t_idx - total_delay
        t_read = np.clip(t_read, 0, length - 1)
        warped = np.interp(t_read, t_idx, audio[:, ch]).astype(np.float32)
        
        # Doubling Depth calculation
        if is_dropouts and args.drop_doubling > 0:
            doub_amt = args.drop_doubling / 100.0
            t_read2 = t_idx - total_delay * 0.8 - (0.015 * sr)
            t_read2 = np.clip(t_read2, 0, length - 1)
            tap2 = np.interp(t_read2, t_idx, audio[:, ch]).astype(np.float32)
            blend = np.clip(chew_env + tracking_env, 0, 1) * doub_amt
            warped = warped * (1.0 - blend) + tap2 * blend
            
        audio[:, ch] = warped

    # 4. TAPE HISS
    print(f"Mixing Analog Tape Hiss ({args.noise_type.capitalize()})...")
    noise_base = np.random.randn(length, channels).astype(np.float32)
    
    if args.noise_type == 'brown':
        b, a = [1.0],[1.0, -0.99]
        noise = sig.lfilter(b, a, noise_base, axis=0).astype(np.float32)
    elif args.noise_type == 'pink':
        # Economy IIR pink noise approximation filter coefficients
        b =[0.049922035, -0.095993537, 0.050612699, -0.004408786]
        a =[1.0, -2.494956002, 2.017265875, -0.522189400]
        noise = sig.lfilter(b, a, noise_base, axis=0).astype(np.float32)
    else: # White
        noise = noise_base
        
    noise -= np.mean(noise, axis=0)
    noise /= (np.max(np.abs(noise), axis=0) + 1e-8)
    
    hiss_level = (args.noise_vol / 100.0) * 0.1
    
    if is_vhs:
        noise = apply_lowpass(noise, 6000, sr)
        hiss_mod = generate_spline_lfo(length, 2.0, sr).reshape(-1, 1)
        noise *= (1.0 + hiss_mod * 0.4)
        hiss_level *= 1.5

    audio += noise * hiss_level

    # 5. DROPOUT INTENSITY (Filter & Vol)
    if is_dropouts and args.drop_filter_vol > 0:
        print("Applying Tape Head Separation & Dropouts...")
        filt_vol_amt = args.drop_filter_vol / 100.0
        dropout_env_2d = dropout_env.reshape(-1, 1)
        
        muffled = apply_lowpass(audio, max(300, 15000 - filt_vol_amt*14700), sr)
        audio = audio * (1.0 - dropout_env_2d * (filt_vol_amt * 0.95))
        audio = audio * (1.0 - dropout_env_2d) + muffled * dropout_env_2d

    if is_vhs:
        print("Injecting VHS Head Switching & Electrical Hum...")
        hum_freq = float(np.random.choice([50.0, 60.0]))
        hum_t = np.arange(length, dtype=np.float32).reshape(-1, 1)
        hum = np.sin(2 * np.pi * hum_freq * hum_t / sr)
        hum += 0.5 * np.sin(2 * np.pi * (hum_freq*2) * hum_t / sr)
        hum += 0.25 * np.sin(2 * np.pi * (hum_freq*3) * hum_t / sr)
        
        pulse_freq = hum_freq / 2.0
        pulse = sig.sawtooth(2 * np.pi * pulse_freq * hum_t / sr)
        pulse = np.clip(pulse, 0.8, 1.0) - 0.8
        hum_signal = (hum * 0.5 + pulse * 5.0) * 0.015
        
        if channels > 1:
            hum_signal = np.repeat(hum_signal, channels, axis=1)
        audio += hum_signal

    print("Normalizing and finalizing format...")
    audio = np.tanh(audio)
    
    temp_out = tempfile.NamedTemporaryFile(suffix='.wav', delete=False).name
    sf.write(temp_out, audio, sr, subtype='PCM_16')

    # FFMPEG Encoding Pass
    cmd =['ffmpeg', '-y', '-i', temp_out]
    if args.samplerate:
        cmd.extend(['-ar', str(args.samplerate)])
        
    if args.out_format.lower() == 'mp3':
        cmd.extend(['-codec:a', 'libmp3lame'])
        if args.bitrate: cmd.extend(['-b:a', args.bitrate])
    else:
        cmd.extend(['-codec:a', 'pcm_s16le']) 
        if args.bitdepth == '24': cmd[-1] = 'pcm_s24le'
        elif args.bitdepth == '32': cmd[-1] = 'pcm_f32le'
            
    cmd.append(args.output)
    
    try:
        subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception as e:
        print(f"Error encoding with ffmpeg: {e}")
    finally:
        os.remove(temp_in)
        os.remove(temp_out)
        
    print(f"Success! Saved to: {args.output}")


# ==========================================
# CLI Arguments Parser
# ==========================================

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Procedural Analog Tape Simulator")
    parser.add_argument('-i', '--input', required=True)
    parser.add_argument('-o', '--output', required=True)
    parser.add_argument('-t', '--type', choices=['A', 'B'], default='A')
    parser.add_argument('--out-format', choices=['wav', 'mp3'], default='wav')
    parser.add_argument('--samplerate', type=int, default=44100)
    parser.add_argument('--bitdepth', choices=['16', '24', '32'], default='24')
    parser.add_argument('--bitrate', default='320k')
    
    # New Configurable Parameters
    parser.add_argument('--sat-amt', type=float, default=25.0)
    parser.add_argument('--flutter-rate', type=float, default=15.0)
    parser.add_argument('--flutter-depth', type=float, default=20.0)
    parser.add_argument('--flutter-var', type=float, default=10.0)
    parser.add_argument('--wow-rate', type=float, default=1.0)
    parser.add_argument('--wow-depth', type=float, default=20.0)
    parser.add_argument('--wow-var', type=float, default=10.0)
    parser.add_argument('--noise-type', choices=['brown', 'pink', 'white'], default='pink')
    parser.add_argument('--noise-vol', type=float, default=10.0)
    parser.add_argument('--dropouts', type=int, default=1)
    parser.add_argument('--drop-filter-vol', type=float, default=50.0)
    parser.add_argument('--drop-doubling', type=float, default=30.0)
    parser.add_argument('--drop-delay-drift', type=float, default=30.0)
    parser.add_argument('--drop-prob', type=float, default=20.0)
    
    args = parser.parse_args()
    
    try:
        process_tape_sim(args)
    except Exception as e:
        print(f"\n[!] An error occurred during processing: {e}")
        sys.exit(1)
