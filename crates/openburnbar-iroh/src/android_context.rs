use std::ffi::c_void;

use jni::{
    errors::LogContextErrorAndDefault,
    objects::{JClass, JObject},
    sys::{jboolean, JNI_TRUE},
    Env, EnvUnowned,
};

#[no_mangle]
pub extern "system" fn Java_com_openburnbar_irohrelay_OpenBurnBarIrohNativeContext_installAndroidContext<
    'local,
>(
    mut env: EnvUnowned<'local>,
    _class: JClass<'local>,
    application_context: JObject<'local>,
) -> jboolean {
    env.with_env(|env| -> jni::errors::Result<_> {
        install(env, application_context)?;
        Ok(JNI_TRUE)
    })
    .resolve_with::<LogContextErrorAndDefault, _>(|| {
        "installing OpenBurnBar iroh Android context".to_string()
    })
}

fn install(env: &mut Env<'_>, application_context: JObject<'_>) -> Result<(), jni::errors::Error> {
    if application_context.is_null() {
        return Ok(());
    }

    let java_vm = env.get_java_vm()?;
    let global_context = env.new_global_ref(application_context)?;
    let java_vm_ptr = java_vm.get_raw() as *mut c_void;
    let context_ptr = global_context.into_raw() as *mut c_void;

    // iroh's Android DNS reader consults ndk_context. The app owns this
    // process-lifetime Application reference so Endpoint::builder can safely
    // read system DNS before binding.
    unsafe {
        iroh_dns::install_android_jni_context(java_vm_ptr, context_ptr);
    }
    Ok(())
}
