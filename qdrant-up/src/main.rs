use anyhow::{Context, Result};
use clap::{Parser, ValueEnum};
use qdrant_client::qdrant::{
    CreateCollectionBuilder, Distance, PointStruct, UpsertPointsBuilder, VectorParamsBuilder,
};
use qdrant_client::config::CompressionEncoding;
use qdrant_client::{Payload, Qdrant};
use serde::Deserialize;
use std::fs;
use std::path::PathBuf;
use std::time::Duration;
use url::Url;

#[derive(Debug, Clone, ValueEnum)]
enum CompressionArg {
    None,
    Gzip,
    Zstd,
    Lz4,
}

#[derive(Parser)]
#[command(name = "qdrant-up")]
#[command(about = "Upload embeddings to Qdrant vector database")]
struct Args {
    #[arg(long)]
    url: String,

    #[arg(long)]
    api_key: String,

    #[arg(long)]
    input: PathBuf,

    #[arg(long, default_value = "documents")]
    collection: String,

    #[arg(long, default_value = "768")]
    dimensions: u64,

    #[arg(long, default_value = "100")]
    batch_size: usize,

    #[arg(long, default_value = "30")]
    timeout: u64,

    #[arg(long, default_value = "3")]
    pool_size: usize,

    #[arg(long, value_enum, default_value = "none")]
    compression: CompressionArg,
}

#[derive(Deserialize)]
struct InputData {
    points: Vec<Point>,
}

#[derive(Deserialize)]
struct Point {
    id: String,
    vector: Vec<f32>,
    payload: serde_json::Value,
}

fn ensure_grpc_port(url_str: &str) -> Result<String> {
    let mut parsed = Url::parse(url_str).context("Invalid URL")?;

    // If no port specified, add 6334 for gRPC
    if parsed.port().is_none() {
        parsed.set_port(Some(6334)).map_err(|_| anyhow::anyhow!("Failed to set port"))?;
    }

    Ok(parsed.to_string())
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();

    let content = fs::read_to_string(&args.input)
        .with_context(|| format!("Failed to read input file: {:?}", args.input))?;

    let data: InputData =
        serde_json::from_str(&content).context("Failed to parse input JSON")?;

    eprintln!("Loaded {} points from input file", data.points.len());
    eprintln!("Timeout: {}s, Pool size: {}, Compression: {:?}",
              args.timeout, args.pool_size, args.compression);

    // Ensure URL has port 6334 for gRPC (Qdrant Cloud requirement)
    let url = ensure_grpc_port(&args.url)?;
    eprintln!("Connecting to: {}", url);

    let mut client_builder = Qdrant::from_url(&url)
        .api_key(args.api_key.clone())
        .timeout(Duration::from_secs(args.timeout))
        .keep_alive_while_idle()
        .skip_compatibility_check();

    match args.compression {
        CompressionArg::None => {},
        CompressionArg::Gzip => {
            client_builder = client_builder.compression(Some(CompressionEncoding::Gzip));
        },
        CompressionArg::Zstd => {
            eprintln!("Warning: Zstd compression not available, using Gzip");
            client_builder = client_builder.compression(Some(CompressionEncoding::Gzip));
        },
        CompressionArg::Lz4 => {
            eprintln!("Warning: LZ4 compression not directly supported, using Gzip");
            client_builder = client_builder.compression(Some(CompressionEncoding::Gzip));
        },
    }

    let client = client_builder
        .build()
        .context("Failed to create Qdrant client")?;

    let exists: bool = client.collection_exists(&args.collection).await?;
    if !exists {
        eprintln!("Creating collection: {}", args.collection);
        client
            .create_collection(
                CreateCollectionBuilder::new(&args.collection).vectors_config(
                    VectorParamsBuilder::new(args.dimensions, Distance::Cosine),
                ),
            )
            .await
            .context("Failed to create collection")?;
    }

    let total_batches = (data.points.len() + args.batch_size - 1) / args.batch_size;

    for (batch_idx, chunk) in data.points.chunks(args.batch_size).enumerate() {
        let points: Vec<PointStruct> = chunk
            .iter()
            .map(|p| {
                PointStruct::new(
                    p.id.clone(),
                    p.vector.clone(),
                    Payload::try_from(p.payload.clone()).unwrap(),
                )
            })
            .collect();

        client
            .upsert_points(UpsertPointsBuilder::new(&args.collection, points))
            .await
            .with_context(|| format!("Failed to upsert batch {}", batch_idx))?;

        println!(
            "progress:{{\"batch\":{},\"total\":{},\"points\":{}}}",
            batch_idx + 1,
            total_batches,
            chunk.len()
        );
    }

    println!("done:{{\"total_points\":{}}}", data.points.len());
    Ok(())
}
