fn main() {
    // Arch packages the CBLAS API separately from libblas. transcribe.cpp's
    // mel frontend uses this API even with its Vulkan backend selected.
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("linux") {
        println!("cargo:rustc-link-lib=cblas");
    }
}
