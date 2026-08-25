#if MLXEngine
let mlxEngineCompiledIn = true
#else
/// Present so the module is never empty when the trait is off.
let mlxEngineCompiledIn = false
#endif
