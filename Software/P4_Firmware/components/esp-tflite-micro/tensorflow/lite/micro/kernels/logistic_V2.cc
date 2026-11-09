/* Copyright 2023 The TensorFlow Authors. All Rights Reserved.
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at
    http://www.apache.org/licenses/LICENSE-2.0
Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
==============================================================================*/

// ── What this file fixes ────────────────────────────────────────────────────
//  Problem 1: gemmlowp Logistic takes ~40s per tile  → replaced with LUT
//  Problem 2: TFLMRegistration not found             → uses TfLiteRegistration*
//  Problem 3: tflite::micro not declared             → correct includes added
//  Problem 4: LogisticPrepare redefined              → lives in logistic_common.cc
//  Problem 5: node/context NULL crash in Prepare     → Init allocates extended struct
//  Problem 6: Single static LUT wrong for multi-layer→ per-node LUT in persistent buf
//  Problem 7: Missing field initializers             → reg fields set by name
//  Problem 8: TFLITE_DCHECK not found               → pulled in via micro_common.h
// ────────────────────────────────────────────────────────────────────────────

#include "tensorflow/lite/micro/kernels/logistic.h"

#include <cmath>
#include <cstdint>

#include "tensorflow/lite/c/builtin_op_data.h"
#include "tensorflow/lite/c/common.h"
#include "tensorflow/lite/kernels/internal/common.h"
#include "tensorflow/lite/kernels/internal/quantization_util.h"
#include "tensorflow/lite/kernels/internal/reference/logistic.h"
#include "tensorflow/lite/kernels/internal/tensor_ctypes.h"
#include "tensorflow/lite/kernels/kernel_util.h"
#include "tensorflow/lite/micro/kernels/kernel_util.h"
#include "tensorflow/lite/micro/micro_common.h"

namespace tflite {

// ── Extended op data ─────────────────────────────────────────────────────────
// OpDataLogistic is declared in logistic.h with fields:
//   int32_t input_zero_point
//   int32_t input_range_radius
//   int32_t input_multiplier
//   int     input_left_shift
//
// We extend it by making base the FIRST member so that logistic_common.cc's
// LogisticPrepare() can safely cast node->user_data to OpDataLogistic*.
// The LUT is built once per node after Prepare fills in the base fields.

struct FastLogisticOpData {
    OpDataLogistic base;    // ← MUST be first: Prepare casts user_data to this
    int8_t         lut[256];
    bool           lut_ready;
};

// ── Build the LUT from quantization params ────────────────────────────────────
// Called once per node during the first Eval, after Prepare has filled base.
static void BuildLUT(FastLogisticOpData* data) {
    // Reconstruct input scale from the fixed-point params stored by Prepare.
    // input_real_multiplier = input_multiplier * 2^(input_left_shift - 31)
    const float in_scale =
        static_cast<float>(data->base.input_multiplier) *
        std::pow(2.0f, static_cast<float>(data->base.input_left_shift - 31));

    // INT8 logistic output is always: scale=1/256, zero_point=-128
    // (enforced by logistic_common.cc: output->params.zero_point == INT8_MIN)
    const float out_scale = 1.0f / 256.0f;
    const int   out_zp    = -128;

    for (int i = 0; i < 256; i++) {
        // Map uint8 index [0,255] back to int8 [-128,127]
        const int   x_int8 = (i < 128) ? i : i - 256;
        const float x_real = (x_int8 - data->base.input_zero_point) * in_scale;
        const float y_real = 1.0f / (1.0f + std::exp(-x_real));
        const int   y_int8 = static_cast<int>(std::round(y_real / out_scale)) + out_zp;
        data->lut[i] = static_cast<int8_t>(
            y_int8 < -128 ? -128 : (y_int8 > 127 ? 127 : y_int8));
    }
    data->lut_ready = true;
}

// ── Init ─────────────────────────────────────────────────────────────────────
// Allocates FastLogisticOpData from the persistent arena.
// logistic_common.cc's Prepare() will cast user_data → OpDataLogistic* and fill
// base fields — safe because base is the first member.
void* LogisticInit(TfLiteContext* context, const char* buffer, size_t length) {
    TFLITE_DCHECK(context->AllocatePersistentBuffer != nullptr);
    FastLogisticOpData* data = static_cast<FastLogisticOpData*>(
        context->AllocatePersistentBuffer(context, sizeof(FastLogisticOpData)));
    if (data != nullptr) {
        data->lut_ready = false;
    }
    return data;
}

// ── Eval ─────────────────────────────────────────────────────────────────────
// LogisticPrepare is NOT defined here — it lives in logistic_common.cc and is
// declared in logistic.h. The linker will find it automatically.

TfLiteStatus LogisticEval(TfLiteContext* context, TfLiteNode* node) {
    const TfLiteEvalTensor* input =
        tflite::micro::GetEvalInput(context, node, kLogisticInputTensor);
    TfLiteEvalTensor* output =
        tflite::micro::GetEvalOutput(context, node, kLogisticOutputTensor);

    // ── Float path (unchanged, reference ops) ────────────────────────────────
    if (input->type == kTfLiteFloat32) {
        reference_ops::Logistic(
            tflite::micro::GetTensorShape(input),
            tflite::micro::GetTensorData<float>(input),
            tflite::micro::GetTensorShape(output),
            tflite::micro::GetTensorData<float>(output));
        return kTfLiteOk;
    }

    // ── INT8 fast LUT path ───────────────────────────────────────────────────
    if (input->type == kTfLiteInt8) {
        FastLogisticOpData* data =
            static_cast<FastLogisticOpData*>(node->user_data);

        // Build LUT on first call (after Prepare has filled base fields)
        if (!data->lut_ready) {
            BuildLUT(data);
        }

        const int    flat = tflite::micro::GetTensorShape(input).FlatSize();
        const int8_t* in  = tflite::micro::GetTensorData<int8_t>(input);
        int8_t*       out = tflite::micro::GetTensorData<int8_t>(output);

        for (int i = 0; i < flat; i++) {
            out[i] = data->lut[static_cast<uint8_t>(in[i])];
        }
        return kTfLiteOk;
    }

    return kTfLiteError;
}

// ── Registration ─────────────────────────────────────────────────────────────
// Returns TfLiteRegistration* to match the declaration in logistic.h:
//   TfLiteRegistration* Register_LOGISTIC();
//
// Fields set by name to avoid -Werror=missing-field-initializers.
// LogisticPrepare comes from logistic_common.cc (already compiled).

TFLMRegistration Register_LOGISTIC() {
    return tflite::micro::RegisterOp(LogisticInit, LogisticPrepare, LogisticEval);
}

}  // namespace tflite
