/*
 * sbcstream — анализ реального потока, который уходит в DS4.
 *
 * Берёт WAV (16 бит PCM), кодирует его ровно так же, как это делает зонд
 * (SBC, 16 или 32 кГц, joint stereo, заданный bitpool), прогоняет через
 * sbc_decode() и ищет следы повреждений:
 *   - SNR декодированного потока относительно исходного,
 *   - «провалы» — кадры, чья энергия намного ниже соседних,
 *   - разрывы на границах кадров (щелчки).
 *
 * Если поток чистый, а DS4 всё равно прерывается — значит glitch на стороне
 * декодера контроллера, и лечить надо профилем кодирования, а не потоком.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#include "sbc.h"

#define FRAME_SAMPLES 128
#define MAX_FRAMES 4096

static uint16_t u16at(const uint8_t *b, int off)
{
	return (uint16_t)(b[off] | (b[off + 1] << 8));
}

static uint32_t u32at(const uint8_t *b, int off)
{
	return (uint32_t)b[off] | ((uint32_t)b[off + 1] << 8) |
	       ((uint32_t)b[off + 2] << 16) | ((uint32_t)b[off + 3] << 24);
}

/* Возвращает левый канал WAV; если файл не 16-битный — выходит с ошибкой. */
static int16_t *load_wav(const char *path, int *outRate, int *outFrames)
{
	FILE *f = fopen(path, "rb");
	if (!f) { fprintf(stderr, "не открыть %s\n", path); return NULL; }
	fseek(f, 0, SEEK_END);
	long size = ftell(f);
	fseek(f, 0, SEEK_SET);
	uint8_t *buf = malloc((size_t)size);
	if (fread(buf, 1, (size_t)size, f) != (size_t)size) { fclose(f); free(buf); return NULL; }
	fclose(f);

	if (size < 44 || memcmp(buf, "RIFF", 4) || memcmp(buf + 8, "WAVE", 4)) {
		fprintf(stderr, "не WAV\n");
		free(buf);
		return NULL;
	}
	int channels = 0, rate = 0, bits = 0;
	int dataOff = -1;
	long dataLen = 0;
	int off = 12;
	while (off + 8 <= size) {
		uint32_t cs = u32at(buf, off + 4);
		int body = off + 8;
		if (!memcmp(buf + off, "fmt ", 4)) {
			channels = u16at(buf, body + 2);
			rate = (int)u32at(buf, body + 4);
			bits = u16at(buf, body + 14);
		} else if (!memcmp(buf + off, "data", 4)) {
			dataOff = body;
			dataLen = cs;
			if (dataOff + dataLen > size) dataLen = size - dataOff;
			break;
		}
		off = body + (int)cs + (cs & 1);
	}
	if (dataOff < 0 || bits != 16 || channels < 1) {
		fprintf(stderr, "поддерживается только PCM 16 бит\n");
		free(buf);
		return NULL;
	}
	int frames = (int)(dataLen / 2 / channels);
	int16_t *mono = malloc(sizeof(int16_t) * (size_t)frames);
	for (int i = 0; i < frames; i++) mono[i] = (int16_t)u16at(buf, dataOff + 2 * (i * channels));
	free(buf);
	*outRate = rate;
	*outFrames = frames;
	return mono;
}

int main(int argc, char **argv)
{
	if (argc < 2) {
		fprintf(stderr, "использование: sbcstream <file.wav> [bitpool] [rate] [joint|dual|mono]\n");
		return 2;
	}
	const char *path = argv[1];
	int bitpool = argc > 2 ? atoi(argv[2]) : 12;
	int rate = argc > 3 ? atoi(argv[3]) : 16000;
	int mode = argc > 4 ? (strcmp(argv[4], "dual") == 0 ? SBC_MODE_DUAL_CHANNEL :
			       (strcmp(argv[4], "mono") == 0 ? SBC_MODE_MONO : SBC_MODE_JOINT_STEREO))
			    : SBC_MODE_JOINT_STEREO;

	int wavRate = 0, wavFrames = 0;
	int16_t *wav = load_wav(path, &wavRate, &wavFrames);
	int16_t *wavR = NULL;
	{
		/* читаем файл ещё раз, чтобы взять правый канал */
		FILE *f = fopen(path, "rb");
		if (f) {
			fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
			uint8_t *b = malloc((size_t)sz);
			if (fread(b, 1, (size_t)sz, f) == (size_t)sz) {
				int off = 12, ch2 = 0; long dl = 0; int doff = -1;
				while (off + 8 <= sz) {
					uint32_t cs = u32at(b, off + 4); int body = off + 8;
					if (!memcmp(b + off, "fmt ", 4)) ch2 = u16at(b, body + 2);
					else if (!memcmp(b + off, "data", 4)) { doff = body; dl = cs; break; }
					off = body + (int)cs + (cs & 1);
				}
				if (doff >= 0 && ch2 >= 2) {
					int nf = (int)(dl / 2 / ch2);
					wavR = malloc(sizeof(int16_t) * (size_t)nf);
					for (int i = 0; i < nf; i++)
						wavR[i] = (int16_t)u16at(b, doff + 2 * (i * ch2 + 1));
				}
			}
			free(b);
		}
		fclose(f);
	}
	if (!wav) return 1;
	if (wavRate != rate) {
		fprintf(stderr, "частота WAV (%d) не совпадает с целевой (%d) — пересемплируйте\n",
			wavRate, rate);
		free(wav);
		return 1;
	}

	sbc_t enc, dec;
	if (sbc_init(&enc, 0) < 0) return 1;
	int loud = (argc > 5 && strcmp(argv[5], "loud") == 0);
	if (sbc_configure(&enc, rate == 16000 ? SBC_FREQ_16000 : SBC_FREQ_32000, mode,
			  loud ? SBC_AM_LOUDNESS : SBC_AM_SNR, SBC_SB_8, SBC_BLK_16, bitpool) < 0) return 1;
	if (sbc_init(&dec, 0) < 0) return 1;

	int16_t pcm[FRAME_SAMPLES * 2];
	uint8_t encoded[512];
	uint8_t decoded[FRAME_SAMPLES * 2 * 2];
	int nch = (mode == SBC_MODE_MONO) ? 1 : 2;

	int frames = wavFrames / FRAME_SAMPLES;
	if (frames > MAX_FRAMES) frames = MAX_FRAMES;

	double *rms = calloc((size_t)frames, sizeof(double));
	double *outStream = calloc((size_t)(frames * FRAME_SAMPLES + FRAME_SAMPLES), sizeof(double));
	int outLen = 0;
	double *jump = calloc((size_t)frames, sizeof(double));
	double sig2 = 0, err2 = 0, out2 = 0;
	int decodeFail = 0;
	int anomalies = 0;
	unsigned char cfgByte = (mode == SBC_MODE_MONO) ? 0x73 :
			       (mode == SBC_MODE_DUAL_CHANNEL) ? 0x53 : 0x7F;
	int16_t prevLast = 0;
	int frameLen = 0;
	double maxJump = 0;
	int maxJumpFrame = -1;

	for (int f = 0; f < frames; f++) {
		for (int i = 0; i < FRAME_SAMPLES; i++) {
			int16_t v = wav[f * FRAME_SAMPLES + i];
			if (nch == 1) pcm[i] = v;
			else { pcm[2 * i] = v; pcm[2 * i + 1] = v; }
		}
		ssize_t written = 0;
		if (sbc_encode(&enc, pcm, nch == 1 ? FRAME_SAMPLES * 2 : sizeof(pcm),
			       encoded, sizeof(encoded), &written) <= 0) {
			decodeFail++;
			continue;
		}
		frameLen = (int)written;
		/* Проверка заголовка кадра: syncword, config, bitpool, CRC-8. */
		{
			unsigned char b0 = encoded[0], b1 = encoded[1], b2 = encoded[2], b3 = encoded[3];
			unsigned char crc = 0xFF, x;
			unsigned char hdr[3] = { b0, b1, b2 };
			for (int k = 0; k < 3; k++) {
				crc ^= hdr[k];
				for (int bit = 0; bit < 8; bit++) {
					crc = (crc & 0x80) ? (unsigned char)((crc << 1) ^ 0x07) : (unsigned char)(crc << 1);
				}
			}
			if (b0 != 0x9C || b1 != cfgByte || b2 != (unsigned char)bitpool || crc != b3) {
				printf("  !! аномалия в кадре %d: %02X %02X %02X %02X (ожидалось 9C %02X %02X, CRC %02X)\n",
				       f, b0, b1, b2, b3, cfgByte, (unsigned char)bitpool, crc);
				anomalies++;
			}
			(void)x;
		}
		size_t dw = 0;
		if (sbc_decode(&dec, encoded, (size_t)written, decoded, sizeof(decoded), &dw) <= 0) {
			decodeFail++;
			continue;
		}
		int samples = (int)(dw / 2 / nch);
		double sum = 0;
		int16_t first = 0;
		for (int i = 0; i < samples; i++) {
			int16_t o = (int16_t)(decoded[2 * (i * nch)] | (decoded[2 * (i * nch) + 1] << 8));
			if (i == 0) first = o;
			double ref = wav[f * FRAME_SAMPLES + i];
			double e = (double)o - ref;
			sig2 += ref * ref;
			err2 += e * e;
			out2 += (double)o * o;
			sum += (double)o * o;
		}
		for (int i = 0; i < samples && outLen < frames * FRAME_SAMPLES; i++) {
			int16_t o = (int16_t)(decoded[2 * (i * nch)] | (decoded[2 * (i * nch) + 1] << 8));
			outStream[outLen++] = (double)o;
		}
		rms[f] = sqrt(sum / (samples ? samples : 1));
		jump[f] = fabs((double)first - (double)prevLast);
		if (jump[f] > maxJump) { maxJump = jump[f]; maxJumpFrame = f; }
		prevLast = (int16_t)(decoded[2 * ((samples - 1) * nch)] |
				     (decoded[2 * ((samples - 1) * nch) + 1] << 8));
	}

	printf("=== %s, %d Гц, bitpool %d, кадр %d B ===\n", path, rate, bitpool, frameLen);
	printf("кадров: %d, ошибок декодирования: %d, аномалий заголовка: %d\n",
	       frames, decodeFail, anomalies);
	/* Честный SNR: у декодера SBC есть задержка (~23 сэмпла), ищем её. */
	double bestSnr = -1e9;
	int bestDelay = 0;
	for (int d = 0; d < 64; d++) {
		double s2 = 0, e2 = 0;
		int n = outLen - d;
		if (n <= 0) break;
		for (int i = 0; i < n; i++) {
			double r = wav[d + i];
			double e = outStream[i] - r;
			s2 += r * r;
			e2 += e * e;
		}
		double sn = 10.0 * log10((s2 + 1e-9) / (e2 + 1e-9));
		if (sn > bestSnr) { bestSnr = sn; bestDelay = d; }
	}
	double snr = bestSnr;
	printf("SNR потока: %.1f дБ (задержка декодера %d сэмпл), RMS выхода: %.0f\n",
	       snr, bestDelay, sqrt(out2 / (frames * FRAME_SAMPLES)));
	if (wavR) {
		double bs = -1e9, be = 1e9; int bd = 0;
		for (int d = 0; d < 64; d++) {
			double s2 = 0, e2 = 0; int n = outLen - d;
			if (n <= 0) break;
			for (int i = 0; i < n; i++) {
				double r = wavR[d + i];
				double e = outStream[i] - r;
				s2 += r * r; e2 += e * e;
			}
			double sn = 10.0 * log10((s2 + 1e-9) / (e2 + 1e-9));
			if (sn > bs) { bs = sn; bd = d; }
		}
		printf("SNR против ПРАВОГО канала оригинала: %.1f дБ (задержка %d)\n", bs, bd);
	}

	/* Провалы: кадр значительно тише соседей. */
	int dropouts = 0;
	printf("\nкадры с провалом энергии (>12 дБ ниже медианы соседей):\n");
	for (int f = 1; f + 1 < frames; f++) {
		double m = (rms[f - 1] + rms[f + 1]) / 2.0;
		if (m > 100 && rms[f] < m / 4.0) {
			printf("  кадр %4d (%.2f с): RMS %6.0f при среднем %6.0f\n",
			       f, f * FRAME_SAMPLES / (double)rate, rms[f], m);
			dropouts++;
		}
	}
	if (!dropouts) printf("  нет\n");

	/* Разрывы на границах кадров. */
	printf("\nмаксимальный разрыв на границе кадров: %.0f (кадр %d)\n", maxJump, maxJumpFrame);
	printf("кадров с разрывом > 4000: ");
	int bigJumps = 0;
	for (int f = 0; f < frames; f++) if (jump[f] > 4000) bigJumps++;
	printf("%d\n", bigJumps);

	/* Профиль энергии — чтобы увидеть «дыры» в потоке. */
	/* Метрика с выравниванием по окнам: для сигналов с резкими транзиентами
	   MDCT сдвигает их на разное число сэмплов, и обычный SNR «по кадрам»
	   даёт ~0 дБ даже для идеального кодека. Здесь в каждом окне ищем
	   свой сдвиг — остаётся честная оценка верности передачи. */
	printf("\nSNR по 20 мс с локальным выравниванием (медиана):\n");
	{
		int w = rate / 50;
		double meds[4096];
		int mc = 0;
		for (int start = 0; start + w < outLen; start += w) {
			double bs = -1e9;
			for (int d = 0; d < 96; d++) {
				double s2 = 0, e2 = 0;
				int n = w;
				if (start + d + n > outLen) n = outLen - start - d;
				if (n <= 0) break;
				for (int i = 0; i < n; i++) {
					double r = wav[start + d + i];
					double e = outStream[start + i] - r;
					s2 += r * r; e2 += e * e;
				}
				double sn = 10.0 * log10((s2 + 1e-9) / (e2 + 1e-9));
				if (sn > bs) bs = sn;
			}
			if (mc < 4096) meds[mc++] = bs;
		}
		for (int i = 1; i < mc; i++) {
			double v = meds[i];
			int k = i - 1;
			while (k >= 0 && meds[k] > v) { meds[k + 1] = meds[k]; k--; }
			meds[k + 1] = v;
		}
		printf("  медиана: %.1f дБ, 10%%: %.1f, 90%%: %.1f (окон %d)\n",
		       meds[mc / 2], meds[mc / 10], meds[(mc * 9) / 10], mc);
	}

	/* Локальный SNR по окнам времени: если он падает со временем, сигнал
	   «уезжает» (расхождение частот), а не просто шурит. */
	printf("\nSNR по 0.5 с (локальное выравнивание до 64 сэмплов):\n");
	{
		int win = rate / 2;
		for (int start = 0; start + win < outLen; start += win) {
			double bs = -1e9, be = 1e9;
			for (int d = 0; d < 64; d++) {
				double s2 = 0, e2 = 0;
				int n = win;
				if (start + d + n > outLen) n = outLen - start - d;
				if (n <= 0) break;
				for (int i = 0; i < n; i++) {
					double r = wav[start + d + i];
					double e = outStream[start + i] - r;
					s2 += r * r; e2 += e * e;
				}
				double sn = 10.0 * log10((s2 + 1e-9) / (e2 + 1e-9));
				if (sn > bs) { bs = sn; }
			}
			printf("  %5.2f с: %6.1f дБ\n", start / (double)rate, bs);
		}
	}

	printf("\nпрофиль энергии по 10 кадров (дБFS):\n");
	for (int f = 0; f < frames; f += 10) {
		double sum = 0;
		int n = 0;
		for (int i = f; i < f + 10 && i < frames; i++) { sum += rms[i] * rms[i]; n++; }
		double r = sqrt(sum / n);
		double db = r > 0 ? 20 * log10(r / 32768.0) : -99;
		printf("  %5.2f с %6.1f дБ %s\n", f * FRAME_SAMPLES / (double)rate, db,
		       "#", 0);
	}
	/* Дамп декодированного потока для внешнего сравнения. */
	if (argc > 6) {
		FILE *out = fopen(argv[6], "wb");
		if (out) {
			uint8_t hdr[44];
			uint16_t ch = (uint16_t)nch, bits = 16, align = (uint16_t)(nch * 2);
			uint32_t sr32 = (uint32_t)rate, br = (uint32_t)(rate * nch * 2), ds = (uint32_t)(outLen * 2);
			memcpy(hdr, "RIFF", 4);
			uint32_t riff = 36 + ds; memcpy(hdr + 4, &riff, 4);
			memcpy(hdr + 8, "WAVEfmt ", 8);
			uint32_t fs = 16; memcpy(hdr + 16, &fs, 4);
			uint16_t one = 1; memcpy(hdr + 20, &one, 2);
			memcpy(hdr + 22, &ch, 2);
			memcpy(hdr + 24, &sr32, 4);
			memcpy(hdr + 28, &br, 4);
			memcpy(hdr + 32, &align, 2);
			memcpy(hdr + 34, &bits, 2);
			memcpy(hdr + 36, "data", 4);
			memcpy(hdr + 40, &ds, 4);
			fwrite(hdr, 1, 44, out);
			for (int i = 0; i < outLen; i++) {
				int16_t v = (int16_t)outStream[i];
				fwrite(&v, 2, 1, out);
			}
			fclose(out);
			printf("декодированный поток сохранён: %s\n", argv[6]);
		}
	}
	free(rms);
	free(jump);
	free(wav);
	return 0;
}
