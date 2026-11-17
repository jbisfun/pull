// Records the enabled cargo features for `pull --version` and `pull status --json`.
fn main() {
    let mut features: Vec<String> = std::env::vars()
        .filter_map(|(k, _)| k.strip_prefix("CARGO_FEATURE_").map(str::to_owned))
        .filter(|f| f != "DEFAULT")
        .map(|f| f.to_lowercase().replace('_', "-"))
        .collect();
    features.sort();
    println!("cargo:rustc-env=PULL_FEATURES={}", features.join(" "));
}
