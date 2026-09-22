import os
import numpy as np
import librosa
import tensorflow as tf
from tensorflow.keras import layers, models
import glob

# Parámetros espectrales idénticos al código de Android/Kotlin
SAMPLE_RATE = 16000
N_FFT = 1024
HOP_LENGTH = 384  # ~24ms por trama
N_MELS = 64
N_FRAMES = 128    # 128 tramas * 384 muestras / 16000 = ~3.07 segundos

def extract_mel_spectrogram(audio_path):
    """
    Carga un archivo de audio, lo convierte a 16kHz y extrae espectrogramas
    de Mel de tamaño 64x128 de forma continua cada 3 segundos.
    """
    try:
        y, sr = librosa.load(audio_path, sr=SAMPLE_RATE)
    except Exception as e:
        print(f"Error cargando {audio_path}: {e}")
        return []

    # Duración en muestras para 3.07 segundos
    chunk_samples = N_FRAMES * HOP_LENGTH
    spectrograms = []

    # Dividir el audio largo en trozos de 3 segundos
    for start in range(0, len(y) - chunk_samples, chunk_samples):
        y_chunk = y[start:start + chunk_samples]
        
        # Calcular espectrograma de Mel (escala de potencia)
        mel_spec = librosa.feature.melspectrogram(
            y=y_chunk, 
            sr=SAMPLE_RATE, 
            n_fft=N_FFT, 
            hop_length=HOP_LENGTH, 
            n_mels=N_MELS,
            fmin=20,
            fmax=8000
        )
        
        # Convertir a Decibelios
        mel_db = librosa.power_to_db(mel_spec, ref=np.max)
        
        # Normalizar a rango [0, 1] (basado en piso de -80 dB)
        mel_norm = (mel_db + 80.0) / 80.0
        mel_norm = np.clip(mel_norm, 0.0, 1.0)
        
        # Asegurar dimensiones exactas de (N_MELS, N_FRAMES) para evitar descuadres por padding de Librosa
        if mel_norm.shape[1] > N_FRAMES:
            mel_norm = mel_norm[:, :N_FRAMES]
        elif mel_norm.shape[1] < N_FRAMES:
            mel_norm = np.pad(mel_norm, ((0, 0), (0, N_FRAMES - mel_norm.shape[1])), mode='constant')
            
        spectrograms.append(mel_norm)
        
    return spectrograms

def load_dataset(dataset_path):
    """
    Carga los audios de las tres carpetas y asigna sus etiquetas correspondientes.
    """
    classes = ['acustico', 'groove', 'energetico']
    X = []
    y = []

    for class_idx, class_name in enumerate(classes):
        folder_path = os.path.join(dataset_path, class_name)
        audio_files = glob.glob(os.path.join(folder_path, "*.*")) # Busca mp3, wav, etc.
        
        print(f"Procesando carpeta '{class_name}' ({len(audio_files)} archivos encontrados)...")
        
        for file_path in audio_files:
            specs = extract_mel_spectrogram(file_path)
            for spec in specs:
                X.append(spec)
                y.append(class_idx)
                
    X = np.array(X)
    # Ajustar dimensiones para la CNN: [Batch, Altura, Anchura, Canales]
    X = X.reshape(X.shape[0], N_MELS, N_FRAMES, 1)
    y = np.array(y)
    
    return X, y

def build_model():
    """
    Crea una CNN ligera optimizada para dispositivos móviles (TFLite).
    Utiliza GlobalAveragePooling para reducir drásticamente el peso del modelo.
    """
    model = models.Sequential([
        layers.Input(shape=(N_MELS, N_FRAMES, 1)),
        
        # Bloque 1
        layers.Conv2D(8, (3, 3), padding='same', activation='relu'),
        layers.BatchNormalization(),
        layers.MaxPooling2D((2, 2)),
        layers.Dropout(0.2),
        
        # Bloque 2
        layers.Conv2D(16, (3, 3), padding='same', activation='relu'),
        layers.BatchNormalization(),
        layers.MaxPooling2D((2, 2)),
        layers.Dropout(0.2),
        
        # Bloque 3
        layers.Conv2D(32, (3, 3), padding='same', activation='relu'),
        layers.BatchNormalization(),
        
        # Reducción Global
        layers.GlobalAveragePooling2D(),
        
        # Clasificador (3 clases: acústico, groove, energetico)
        layers.Dense(16, activation='relu'),
        layers.Dropout(0.2),
        layers.Dense(3, activation='softmax')
    ])
    
    model.compile(
        optimizer='adam',
        loss='sparse_categorical_crossentropy',
        metrics=['accuracy']
    )
    
    return model

def train_and_export(dataset_path="dataset"):
    # 1. Cargar y procesar datos
    X, y = load_dataset(dataset_path)
    if len(X) == 0:
        print("Error: No se encontraron datos en la carpeta dataset/. Asegúrate de llenarla primero.")
        return
        
    print(f"Total de segmentos de 3 segundos cargados: {len(X)}")
    
    # Mezclar datos
    indices = np.arange(X.shape[0])
    np.random.shuffle(indices)
    X, y = X[indices], y[indices]
    
    # 2. Compilar modelo
    model = build_model()
    model.summary()
    
    # 3. Entrenar
    print("\nIniciando entrenamiento del modelo...")
    model.fit(
        X, y,
        epochs=30,
        batch_size=16,
        validation_split=0.2
    )
    
    # Guardar modelo Keras temporal
    model.save('music_density_model.keras')
    print("Modelo guardado como 'music_density_model.keras'")
    
    # 4. Convertir a TFLite con Cuantización Int8
    print("\nConvirtiendo a TFLite (Cuantización Int8 para máxima eficiencia)...")
    
    def representative_data_gen():
        # Generador de datos representativos para calibrar la cuantización
        for i in range(min(100, len(X))):
            yield [X[i:i+1].astype(np.float32)]
            
    converter = tf.lite.TFLiteConverter.from_keras_model(model)
    converter.optimizations = [tf.lite.Optimize.DEFAULT]
    converter.representative_dataset = representative_data_gen
    converter.target_spec.supported_ops = [tf.lite.OpsSet.TFLITE_BUILTINS_INT8]
    converter.inference_input_type = tf.int8
    converter.inference_output_type = tf.int8
    
    tflite_model = converter.convert()
    
    output_filename = 'ledcar_density_model.tflite'
    with open(output_filename, 'wb') as f:
        f.write(tflite_model)
        
    print(f"¡Éxito! Modelo cuantizado exportado correctamente a '{output_filename}' ({len(tflite_model)/1024:.1f} KB)")
    print("Copia este archivo a la carpeta 'android/app/src/main/assets/' de tu proyecto Flutter.")

if __name__ == "__main__":
    # Asegurar que las carpetas del dataset existan
    os.makedirs("dataset/acustico", exist_ok=True)
    os.makedirs("dataset/groove", exist_ok=True)
    os.makedirs("dataset/energetico", exist_ok=True)
    
    print("Estructura de carpetas 'dataset/' lista.")
    print("Por favor, copia tus archivos de música en sus respectivas subcarpetas y ejecuta este script.")
    
    # Entrenar una vez que las carpetas tengan archivos:
    train_and_export("dataset")
