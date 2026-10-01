use axum::{
    extract::{DefaultBodyLimit, Multipart, State},
    http::StatusCode,
    routing::{get, post},
    Json, Router,
};
use clap::{Parser, ValueEnum};
use serde_json::{json, Value};
use std::{
    io::Cursor,
    net::SocketAddr,
    path::PathBuf,
    sync::{Arc, Mutex},
    time::Instant,
};
use transcribe_cpp::{
    Backend, Model, ModelOptions, RunOptions, Session, SessionOptions, TimestampKind,
};

mod segment;

const MAX_AUDIO_SECONDS: usize = 120;
const MAX_BODY_BYTES: usize = 4 * 1024 * 1024;
const MODEL_ID: &str = "cohere-transcribe-vulkan";

#[derive(Clone, Copy, Debug, ValueEnum)]
enum Compute {
    Vulkan,
    Cpu,
}

#[derive(Parser)]
struct Args {
    #[arg(long)]
    model: PathBuf,
    #[arg(long, value_enum, default_value = "vulkan")]
    backend: Compute,
    #[arg(long, default_value = "127.0.0.1:8178")]
    bind: SocketAddr,
    #[arg(long, default_value_t = 4)]
    threads: i32,
    /// WAV files to benchmark instead of starting the HTTP service.
    #[arg(long, num_args = 1..)]
    benchmark: Vec<PathBuf>,
    #[arg(long, default_value_t = 3)]
    runs: usize,
    /// Verify Vulkan with a bundled spoken fixture and exit (no HTTP server).
    #[arg(long)]
    probe: bool,
}

struct Engine {
    session: Mutex<Session>,
    backend: String,
    device: String,
    languages: Vec<String>,
}

type ApiError = (StatusCode, Json<Value>);
fn error(status: StatusCode, message: impl ToString) -> ApiError {
    (
        status,
        Json(json!({"error": {"message": message.to_string()}})),
    )
}

fn decode_wav(data: &[u8]) -> Result<Vec<f32>, String> {
    let mut reader = hound::WavReader::new(Cursor::new(data)).map_err(|e| e.to_string())?;
    let spec = reader.spec();
    if spec.channels != 1
        || spec.sample_rate != 16_000
        || spec.sample_format != hound::SampleFormat::Int
        || spec.bits_per_sample != 16
    {
        return Err("Expected 16 kHz, mono, 16-bit PCM WAV".into());
    }
    if reader.duration() == 0 || reader.duration() as usize > MAX_AUDIO_SECONDS * 16_000 {
        return Err(format!(
            "Audio must be between 1 sample and {MAX_AUDIO_SECONDS} seconds"
        ));
    }
    reader
        .samples::<i16>()
        .map(|s| s.map(|v| v as f32 / 32768.0).map_err(|e| e.to_string()))
        .collect()
}

fn run(engine: &Engine, pcm: &[f32], language: String) -> Result<Value, String> {
    let mut session = engine
        .session
        .try_lock()
        .map_err(|_| "Transcription engine is busy")?;
    let start = Instant::now();
    let options = RunOptions {
        language: Some(language),
        timestamps: TimestampKind::None,
        ..Default::default()
    };
    let mut text = Vec::new();
    let mut timings = [0.0; 3];
    let segments = segment::segments(pcm);
    for range in &segments {
        let result = session
            .run(&pcm[range.clone()], &options)
            .map_err(|e| e.to_string())?;
        if !result.text.trim().is_empty() {
            text.push(result.text.trim().to_string());
        }
        timings[0] += result.timings.mel_ms;
        timings[1] += result.timings.encode_ms;
        timings[2] += result.timings.decode_ms;
    }
    let seconds = start.elapsed().as_secs_f64();
    // Do not write transcripts or recordings to service logs.
    eprintln!(
        "transcribed audio_seconds={:.3} elapsed_seconds={seconds:.3} backend={}",
        pcm.len() as f64 / 16000.0,
        engine.backend
    );
    Ok(json!({
        "text": text.join(" "),
        "segments": segments.len(),
        "backend": engine.backend,
        "device": engine.device,
        "audio_seconds": pcm.len() as f64 / 16000.0,
        "elapsed_seconds": seconds,
        "timings_ms": {"mel": timings[0], "encode": timings[1], "decode": timings[2]}
    }))
}

async fn health(State(engine): State<Arc<Engine>>) -> Json<Value> {
    Json(
        json!({"ready": true, "backend": engine.backend, "device": engine.device, "model": MODEL_ID}),
    )
}

async fn transcribe(
    State(engine): State<Arc<Engine>>,
    mut form: Multipart,
) -> Result<Json<Value>, ApiError> {
    let mut audio = None;
    let mut language = "en".to_string();
    while let Some(field) = form
        .next_field()
        .await
        .map_err(|e| error(StatusCode::BAD_REQUEST, e))?
    {
        match field.name().unwrap_or("") {
            "file" => {
                if audio.is_some() {
                    return Err(error(
                        StatusCode::BAD_REQUEST,
                        "Only one audio file is accepted",
                    ));
                }
                audio = Some(
                    field
                        .bytes()
                        .await
                        .map_err(|e| error(StatusCode::BAD_REQUEST, e))?,
                );
            }
            "language" => {
                language = field
                    .text()
                    .await
                    .map_err(|e| error(StatusCode::BAD_REQUEST, e))?
            }
            "model" => {
                let model = field
                    .text()
                    .await
                    .map_err(|e| error(StatusCode::BAD_REQUEST, e))?;
                if model != MODEL_ID {
                    return Err(error(
                        StatusCode::BAD_REQUEST,
                        format!("Loaded model is {MODEL_ID}"),
                    ));
                }
            }
            "response_format" => {
                let format = field
                    .text()
                    .await
                    .map_err(|e| error(StatusCode::BAD_REQUEST, e))?;
                if format != "json" {
                    return Err(error(
                        StatusCode::BAD_REQUEST,
                        "Only response_format=json is supported",
                    ));
                }
            }
            _ => {}
        }
    }
    if !engine.languages.contains(&language) {
        return Err(error(StatusCode::BAD_REQUEST, "Unsupported language"));
    }
    let audio = audio.ok_or_else(|| error(StatusCode::BAD_REQUEST, "Missing audio file"))?;
    let pcm = decode_wav(&audio).map_err(|e| error(StatusCode::BAD_REQUEST, e))?;
    let output = tokio::task::spawn_blocking(move || run(&engine, &pcm, language))
        .await
        .map_err(|_| {
            error(
                StatusCode::INTERNAL_SERVER_ERROR,
                "Transcription task failed",
            )
        })?
        .map_err(|e| error(StatusCode::SERVICE_UNAVAILABLE, e))?;
    Ok(Json(output))
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args = Args::parse();
    if !args.bind.ip().is_loopback() {
        return Err("The server must bind to a loopback address".into());
    }
    if args.threads < 1 || args.threads > 64 || args.runs < 1 {
        return Err("Invalid thread or run count".into());
    }
    transcribe_cpp::init_backends_default()?;
    let backend = match args.backend {
        Compute::Vulkan => Backend::Vulkan,
        Compute::Cpu => Backend::Cpu,
    };
    let started = Instant::now();
    let model = Model::load_with(
        &args.model,
        &ModelOptions {
            backend,
            ..Default::default()
        },
    )?;
    let resolved_device = model.device()?;
    let actual = resolved_device.kind;
    if matches!(args.backend, Compute::Vulkan) && actual != "vulkan" {
        return Err(format!("Vulkan was requested but model uses {actual}").into());
    }
    let device = resolved_device.description;
    if matches!(args.backend, Compute::Vulkan)
        && ["llvmpipe", "lavapipe", "swiftshader", "software"]
            .iter()
            .any(|name| device.to_lowercase().contains(name))
    {
        return Err("Software Vulkan device cannot accelerate dictation".into());
    }
    let session = model.session_with(&SessionOptions {
        n_threads: args.threads,
        ..Default::default()
    })?;
    let engine = Arc::new(Engine {
        session: Mutex::new(session),
        backend: actual,
        device,
        languages: model.capabilities().languages,
    });
    eprintln!(
        "model loaded in {:.3}s backend={} device={}",
        started.elapsed().as_secs_f64(),
        engine.backend,
        engine.device
    );
    if args.probe {
        if !matches!(args.backend, Compute::Vulkan) {
            return Err("The hardware probe requires Vulkan".into());
        }
        let pcm = decode_wav(include_bytes!("../samples/test.wav"))?;
        let result = run(&engine, &pcm, "en".into())?;
        let transcript = result["text"].as_str().unwrap_or_default().to_lowercase();
        if !transcript.contains("meeting")
            || !transcript.contains("thursday")
            || !transcript.contains("afternoon")
        {
            return Err("Vulkan speech probe did not recover the expected words".into());
        }
        println!("{result}");
        return Ok(());
    }
    if !args.benchmark.is_empty() {
        for file in &args.benchmark {
            let pcm = decode_wav(&std::fs::read(file)?)?;
            for trial in 1..=args.runs {
                let mut result = run(&engine, &pcm, "en".into())?;
                result["file"] = json!(file);
                result["run"] = json!(trial);
                println!("{result}");
            }
        }
        return Ok(());
    }
    // Compile/cache GPU kernels before reporting the service ready. Discard
    // any text the model emits for this synthetic silence.
    run(&engine, &vec![0.0; 3 * 16_000], "en".into())?;
    eprintln!("warmup complete");
    let app = Router::new()
        .route("/health", get(health))
        .route("/v1/audio/transcriptions", post(transcribe))
        .layer(DefaultBodyLimit::max(MAX_BODY_BYTES))
        .with_state(engine);
    let listener = tokio::net::TcpListener::bind(args.bind).await?;
    eprintln!("listening on http://{}", args.bind);
    axum::serve(listener, app)
        .with_graceful_shutdown(async {
            let _ = tokio::signal::ctrl_c().await;
        })
        .await?;
    Ok(())
}
