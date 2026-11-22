use piano_engine::{design::Unison, engine::Engine, post::BassBoost};
use std::ptr;

pub struct PianoF1 {
    engine: Engine,
    output: BassBoost,
    targets: [f64; 9],
    control_step: f64,
}

#[no_mangle]
pub extern "C" fn piano_f1_create(sample_rate: f64) -> *mut PianoF1 {
    let mut engine = Engine::with_unison(sample_rate, Unison::Acoustic);

    // Match the remaining voicing defaults in web/index.html and pushSettings() in web/main.js. The worklet
    // passes these values through an f32 ABI before the DSP sees them.
    engine.gain = 0.013_f32 as f64;
    engine.set_hardness(0.45_f32 as f64);
    engine.room_amount = 0.30_f32 as f64;
    engine.knock = 0.8_f32 as f64;
    engine.body = 0.45_f32 as f64;
    engine.prepare_voicings();

    Box::into_raw(Box::new(PianoF1 {
        engine,
        output: BassBoost::new(sample_rate),
        targets: [0.30_f32 as f64, 0.45_f32 as f64, 0.5, 0.5, 0.5, 0.5, 0.5, 1.0, 0.5],
        control_step: -1.0 / (0.025 * sample_rate),
    }))
}

// The Swift audio worker owns this handle. Only the source node calls the
// event and render functions, and it keeps the handle alive until it stops.
#[no_mangle]
pub unsafe extern "C" fn piano_f1_destroy(piano: *mut PianoF1) {
    drop(Box::from_raw(piano));
}

#[no_mangle]
pub unsafe extern "C" fn piano_f1_note_on(piano: *mut PianoF1, note: u32, velocity: f32, soft: bool) {
    (*piano).engine.note_on_with_soft_pedal(note as usize, velocity as f64, soft);
}

#[no_mangle]
pub unsafe extern "C" fn piano_f1_note_off(piano: *mut PianoF1, note: u32) {
    (*piano).engine.note_off(note as usize);
}

#[no_mangle]
pub unsafe extern "C" fn piano_f1_sustain(piano: *mut PianoF1, position: f32) {
    (*piano).engine.set_pedal_position(position as f64);
}

#[no_mangle]
pub unsafe extern "C" fn piano_f1_all_off(piano: *mut PianoF1) {
    (*piano).engine.all_off();
}

#[no_mangle]
pub unsafe extern "C" fn piano_f1_set_parameter(piano: *mut PianoF1, address: u32, amount: f32) {
    let piano = &mut *piano;
    let index = address as usize;
    if index >= piano.targets.len() || !amount.is_finite() {
        return;
    }
    let value = amount.clamp(0.0, 1.0) as f64;
    if piano.targets[index] == value {
        return;
    }
    piano.targets[index] = value;
    match index {
        2 => piano.engine.set_hardness(0.45_f32 as f64 * 2f64.powf((value - 0.5) * 2.0)),
        4 => piano.engine.set_decay(2f64.powf((value - 0.5) * 1.6)),
        5 | 6 => piano.engine.select_voicing(
            (piano.targets[6] * 2.0).round() as usize,
            (piano.targets[5] * 2.0).round() as usize,
        ),
        _ => {}
    }
}

fn smooth(current: f64, target: f64, step: f64) -> f64 {
    let distance = target - current;
    if distance.abs() < 1e-6 {
        target
    } else {
        current + distance * step
    }
}

#[no_mangle]
pub unsafe extern "C" fn piano_f1_render(
    piano: *mut PianoF1,
    left: *mut f32,
    right: *mut f32,
    frames: u32,
) {
    let PianoF1 { engine, output, targets, control_step } = &mut *piano;
    let volume = 0.013_f32 as f64 * (2.0 * targets[8]).powi(2);
    let brightness = 2.0 * targets[3] - 1.0;
    // Use the web AudioWorklet's 128-frame quantum even if Core Audio
    // requests a larger buffer.
    let mut offset = 0;
    let frames = frames as usize;
    while offset < frames {
        let count = (frames - offset).min(128);
        if engine.room_amount != targets[0] || engine.body != targets[1] ||
            engine.brightness != brightness || engine.sympathetic != targets[7] || engine.gain != volume {
            let step = 1.0 - (*control_step * count as f64).exp();
            engine.room_amount = smooth(engine.room_amount, targets[0], step);
            engine.body = smooth(engine.body, targets[1], step);
            engine.brightness = smooth(engine.brightness, brightness, step);
            engine.sympathetic = smooth(engine.sympathetic, targets[7], step);
            engine.gain = smooth(engine.gain, volume, step);
        }
        engine.process(count);
        output.process(&mut engine.out_l[..count], &mut engine.out_r[..count]);
        ptr::copy_nonoverlapping(engine.out_l.as_ptr(), left.add(offset), count);
        ptr::copy_nonoverlapping(engine.out_r.as_ptr(), right.add(offset), count);
        offset += count;
    }
}
