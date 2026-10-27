# FINN smoke test for the KV260 integration path: build FINN's tiny MNIST example (TFC, 1-bit
# weights and activations, from finn/src/finn/qnn-data/build_dataflow) up to the stitched IP,
# targeting the KV260 chip instead of a board shell. We integrate the IP into our own Vivado
# design, so no bitstream, PYNQ driver or deployment package is generated here.
#
# Run from ~/finn:  ./run-docker.sh build_custom <path to this folder>
# Output:           output_tfc_kv260/ (stitched_ip/, report/, ...)

import finn.builder.build_dataflow as build
import finn.builder.build_dataflow_config as build_cfg

cfg = build.DataflowBuildConfig(
    output_dir="output_tfc_kv260",
    fpga_part="xck26-sfvc784-2LV-c",        # the KV260 SOM chip, same as our Vivado projects
    synth_clk_period_ns=10.0,                # pl_clk0 = 100 MHz
    folding_config_file="folding_config.json",
    specialize_layers_config_file="specialize_layers_config.json",
    mvau_wwidth_max=10000,
    # package a synthesized netlist (.dcp) into the IP, so it does not depend on the per-layer
    # HLS IP folders in /tmp/finn_dev_<user> (otherwise Vivado reports "locked subcores")
    stitched_ip_gen_dcp=True,
    generate_outputs=[
        build_cfg.DataflowOutputType.ESTIMATE_REPORTS,
        build_cfg.DataflowOutputType.STITCHED_IP,
        build_cfg.DataflowOutputType.RTLSIM_PERFORMANCE,
        build_cfg.DataflowOutputType.OOC_SYNTH,       # out-of-context synthesis: real resources + timing
    ],
    verify_steps=[
        build_cfg.VerificationStepType.TIDY_UP_PYTHON,
        build_cfg.VerificationStepType.STREAMLINED_PYTHON,
        build_cfg.VerificationStepType.FOLDED_HLS_CPPSIM,
        build_cfg.VerificationStepType.STITCHED_IP_RTLSIM,  # checks the generated RTL against input.npy / expected_output.npy
    ],
    save_intermediate_models=True,
)

build.build_dataflow_cfg("model.onnx", cfg)
