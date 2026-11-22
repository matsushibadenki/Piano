#ifndef PIANO_F1_H
#define PIANO_F1_H

#include <stdbool.h>
#include <stdint.h>

typedef struct PianoF1 PianoF1;

PianoF1 * _Nonnull piano_f1_create(double sample_rate);
void piano_f1_destroy(PianoF1 * _Nonnull piano);
void piano_f1_note_on(PianoF1 * _Nonnull piano, uint32_t note, float velocity, bool soft);
void piano_f1_note_off(PianoF1 * _Nonnull piano, uint32_t note);
void piano_f1_sustain(PianoF1 * _Nonnull piano, float position);
void piano_f1_all_off(PianoF1 * _Nonnull piano);
void piano_f1_set_parameter(PianoF1 * _Nonnull piano, uint32_t address, float amount);
void piano_f1_render(PianoF1 * _Nonnull piano, float * _Nonnull left,
                     float * _Nonnull right, uint32_t frames);

#endif
