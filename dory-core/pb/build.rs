fn main() {
    let protos = ["proto/agent.proto", "proto/control.proto"];
    for p in protos {
        println!("cargo:rerun-if-changed={p}");
    }
    prost_build::compile_protos(&protos, &["proto"]).expect("compile .proto");
}
