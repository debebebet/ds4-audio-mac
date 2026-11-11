/*
 * sbcq — измеритель качества SBC для протокола аудио DS4.
 *
 * Задача: найти битпул, при котором сигнал ещё слышен (после декодирования
 * остаётся тон, а не шум), и одновременно кадр достаточно мал, чтобы вписываться
 * в потолок канала Bluetooth HID (~5 КБ/с).
 *
 * Метод: кодируем синусоиду 1 кГц (амплитуда 0.85) блоками по 128 сэмплов,
 * прогоняем через sbc_decode() и считаем:
 *   - RMS декодированного сигнала (громкость → слышимость),
 *   - SNR относительно исходного сигнала с учётом задержки декодера,
 *   - коэффициент корреляции (насколько сигнал похож на тон).
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#include "sbc.h"

#define FRAME_SAMPLES 128
#define MAX_FRAMES 64
#define MAX_SAMPLES (FRAME_SAMPLES * MAX_FRAMES)

static double refL[MAX_SAMPLES];
static double outL[MAX_SAMPLES];

static void make_tone(double *dst, int offset, double phase, double freq, double rate, double amp)
{
	for (int i = 0; i < FRAME_SAMPLES; i++) {
		double v = sin(phase) * amp;
		dst[offset + i] = v;
		phase += 2.0 * M_PI * freq / rate;
		if (phase > 2.0 * M_PI) phase -= 2.0 * M_PI;
	}
}

static void measure(int mono, int bitpool, int frames)
{
	sbc_t enc, dec;
	int16_t pcm[FRAME_SAMPLES * 2 * 2];
	uint8_t encoded[512];
	uint8_t decoded[FRAME_SAMPLES * 2 * 2];
	double phase = 0.0;
	int nch = mono ? 1 : 2;

	if (sbc_init(&enc, 0) < 0) { printf("sbc_init(enc) не удалась\n"); return; }
	if (sbc_configure(&enc, SBC_FREQ_32000,
			  mono ? SBC_MODE_MONO : SBC_MODE_JOINT_STEREO,
			  SBC_AM_SNR, SBC_SB_8, SBC_BLK_16, bitpool) < 0) {
		printf("sbc_configure не удалась\n");
		return;
	}
	if (sbc_init(&dec, 0) < 0) { printf("sbc_init(dec) не удалась\n"); return; }

	int frameLen = 0;
	int ok = 1;
	int totalSamples = 0;

	for (int f = 0; f < frames; f++) {
		make_tone(refL, f * FRAME_SAMPLES, phase, 1000.0, 32000.0, 0.85);
		phase += 2.0 * M_PI * 1000.0 * FRAME_SAMPLES / 32000.0;
		if (phase > 2.0 * M_PI) phase -= 2.0 * M_PI;

		for (int i = 0; i < FRAME_SAMPLES; i++) {
			int16_t s = (int16_t)(refL[f * FRAME_SAMPLES + i] * 32767.0);
			if (nch == 1) {
				pcm[i] = s;
			} else {
				pcm[2 * i + 0] = s;
				pcm[2 * i + 1] = s;
			}
		}

		ssize_t written = 0;
		ssize_t rc = sbc_encode(&enc, pcm, nch == 1 ? FRAME_SAMPLES * 2 : sizeof(pcm),
					 encoded, sizeof(encoded), &written);
		if (rc < 0 || written <= 0) { ok = 0; break; }
		frameLen = (int)written;

		size_t decWritten = 0;
		rc = sbc_decode(&dec, encoded, (size_t)written, decoded, sizeof(decoded), &decWritten);
		if (rc < 0 || decWritten == 0) { ok = 0; break; }

		int samples = (int)(decWritten / 2 / nch);
		if (totalSamples + samples > MAX_SAMPLES) samples = MAX_SAMPLES - totalSamples;
		for (int i = 0; i < samples; i++) {
			int16_t v = (int16_t)(decoded[2 * (i * nch)] | (decoded[2 * (i * nch) + 1] << 8));
			outL[totalSamples + i] = (double)v;
		}
		totalSamples += samples;
	}

	if (!ok || totalSamples < FRAME_SAMPLES * 2) {
		printf("  %s bitpool %2d: кодирование/декодирование не удалось\n",
		       mono ? "mono " : "joint", bitpool);
		sbc_finish(&enc); sbc_finish(&dec);
		return;
	}

	/* Ищем задержку декодера по МАКСИМУМУ корреляции (тон периодичен,
	   минимум ошибки даёт ложные локальные экстремумы). */
	int bestDelay = 0;
	double bestCorr = -2.0;
	int maxDelay = totalSamples / 2;
	for (int d = 0; d < maxDelay; d++) {
		double num = 0, a2 = 0, b2 = 0;
		int n = totalSamples - d;
		for (int i = 0; i < n; i++) {
			double r = refL[i + d] * 32767.0;
			double o = outL[i];
			num += r * o;
			a2 += r * r;
			b2 += o * o;
		}
		double corr = num / (sqrt(a2 * b2) + 1e-9);
		if (corr > bestCorr) { bestCorr = corr; bestDelay = d; }
	}
	double bestErr = 0;
	{
		int n = totalSamples - bestDelay;
		for (int i = 0; i < n; i++) {
			double e = outL[i] - refL[i + bestDelay] * 32767.0;
			bestErr += e * e;
		}
	}

	double sig2 = 0, out2 = 0, cross = 0;
	int n = totalSamples - bestDelay;
	for (int i = 0; i < n; i++) {
		double r = refL[i + bestDelay] * 32767.0;
		double o = outL[i];
		sig2 += r * r;
		out2 += o * o;
		cross += r * o;
	}
	double snr = 10.0 * log10((sig2 + 1e-9) / (bestErr + 1e-9));
	double corr = bestCorr;
	double rms = sqrt(out2 / n);
	double kbPerSec = (double)frameLen * 250.0 / 1024.0;
	double ceiling = 5000.0 / ((double)frameLen * 250.0) * 100.0;

	printf("  %s bp %2d: кадр %3d B, RMS %7.1f, пик %5d, SNR %6.1f дБ, "
	       "корреляция %5.3f, задержка %3d, %.2f КБ/с, реалтайм ≤ %3.0f %%\n",
	       mono ? "mono " : "joint", bitpool, frameLen, rms,
	       (int)(out2 > 0 ? rms * 1.414 : 0), snr, corr, bestDelay,
	       kbPerSec, ceiling > 999 ? 999 : ceiling);

	sbc_finish(&enc);
	sbc_finish(&dec);
}


/* Шумовая полка кодека: кодируем тишину, декодируем и измеряем уровень
   шума. Всё, что тише этой полки, для контроллера неотличимо от тишины —
   именно это слышно как «прерывания» на тихих участках материала. */
static void measure_floor(int mono, int bitpool, int frames)
{
	sbc_t enc, dec;
	int16_t pcm[FRAME_SAMPLES * 2 * 2];
	uint8_t encoded[512];
	uint8_t decoded[FRAME_SAMPLES * 2 * 2];
	int nch = mono ? 1 : 2;
	int ok = 1;
	double sum2 = 0;
	long n = 0;

	if (sbc_init(&enc, 0) < 0) return;
	if (sbc_configure(&enc, SBC_FREQ_32000,
			  mono ? SBC_MODE_MONO : SBC_MODE_JOINT_STEREO,
			  SBC_AM_SNR, SBC_SB_8, SBC_BLK_16, bitpool) < 0) return;
	if (sbc_init(&dec, 0) < 0) return;

	for (int f = 0; f < frames; f++) {
		memset(pcm, 0, sizeof(pcm));
		ssize_t written = 0;
		if (sbc_encode(&enc, pcm, nch == 1 ? FRAME_SAMPLES * 2 : sizeof(pcm),
			       encoded, sizeof(encoded), &written) <= 0) { ok = 0; break; }
		size_t dw = 0;
		if (sbc_decode(&dec, encoded, (size_t)written, decoded, sizeof(decoded), &dw) <= 0) { ok = 0; break; }
		int samples = (int)(dw / 2 / nch);
		for (int i = 0; i < samples; i++) {
			int16_t v = (int16_t)(decoded[2 * (i * nch)] | (decoded[2 * (i * nch) + 1] << 8));
			sum2 += (double)v * v;
			n++;
		}
	}
	if (ok && n > 0) {
		double rms = sqrt(sum2 / (double)n);
		double db = 20.0 * log10((rms + 1e-9) / 32768.0);
		printf("  %s bp %2d: шумовая полка %6.1f дБFS, "
		       "динамический диапазон %5.1f дБ\n",
		       mono ? "mono " : "joint", bitpool, db, -db);
	}
	sbc_finish(&enc);
	sbc_finish(&dec);
}

int main(int argc, char **argv)
{
	int onlyJoint = (argc > 1 && strcmp(argv[1], "joint") == 0);
	int onlyMono = (argc > 1 && strcmp(argv[1], "mono") == 0);

	printf("=== SBC encode->decode: тон 1 кГц, 32 кГц, 16 блоков, 8 подполос, SNR ===\n");
	if (!onlyMono) {
		printf("Joint stereo:\n");
		int bps[] = {2, 3, 4, 6, 8, 10, 12, 16, 24, 32, 48};
		for (size_t i = 0; i < sizeof(bps) / sizeof(bps[0]); i++) measure(0, bps[i], 40);
	}
	if (!onlyJoint) {
		printf("Шумовая полка (тишина, кодирование->декодирование):\n");
		int fb[] = {8, 10, 12, 14, 16, 20, 24, 32, 48};
		for (size_t i = 0; i < sizeof(fb) / sizeof(fb[0]); i++) measure_floor(0, fb[i], 25);
	}
	if (!onlyJoint) {
		printf("Mono:\n");
		int bps[] = {4, 8, 12, 16, 20, 28};
		for (size_t i = 0; i < sizeof(bps) / sizeof(bps[0]); i++) measure(1, bps[i], 40);
	}
	return 0;
}
