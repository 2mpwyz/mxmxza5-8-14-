import { useEffect, useRef, useState } from "react";
import type { PDFDocumentLoadingTask, PDFDocumentProxy } from "pdfjs-dist";
import pdfWorkerUrl from "pdfjs-dist/build/pdf.worker.min.mjs?url";

const flipLightnessKeepHue = (imageData: ImageData) => {
  const { data } = imageData;
  for (let i = 0; i < data.length; i += 4) {
    const r = data[i] / 255;
    const g = data[i + 1] / 255;
    const b = data[i + 2] / 255;
    const max = Math.max(r, g, b);
    const min = Math.min(r, g, b);
    const delta = max - min;
    const lightness = (max + min) / 2;
    const flipped = 1 - lightness;

    if (delta === 0) {
      data[i] = data[i + 1] = data[i + 2] = flipped * 255;
      continue;
    }

    const saturation = delta / (1 - Math.abs(2 * lightness - 1));
    const chroma = saturation * (1 - Math.abs(2 * flipped - 1));
    const hue =
      max === r ? (g - b) / delta : max === g ? (b - r) / delta + 2 : (r - g) / delta + 4;
    const sector = ((hue % 6) + 6) % 6;
    const x = chroma * (1 - Math.abs((sector % 2) - 1));

    let rp = 0;
    let gp = 0;
    let bp = 0;
    if (sector < 1) [rp, gp] = [chroma, x];
    else if (sector < 2) [rp, gp] = [x, chroma];
    else if (sector < 3) [gp, bp] = [chroma, x];
    else if (sector < 4) [gp, bp] = [x, chroma];
    else if (sector < 5) [rp, bp] = [x, chroma];
    else [rp, bp] = [chroma, x];

    const m = flipped - chroma / 2;
    data[i] = (rp + m) * 255;
    data[i + 1] = (gp + m) * 255;
    data[i + 2] = (bp + m) * 255;
  }
};

interface DarkPdfPagesProps {
  url: string;
  width: number;
}

const DarkPdfPages = ({ url, width }: DarkPdfPagesProps) => {
  const containerRef = useRef<HTMLDivElement>(null);
  const [pdf, setPdf] = useState<PDFDocumentProxy | null>(null);
  const [status, setStatus] = useState<"loading" | "ready" | "error">("loading");

  useEffect(() => {
    let cancelled = false;
    let loadingTask: PDFDocumentLoadingTask | null = null;
    setPdf(null);
    setStatus("loading");

    const load = async () => {
      const pdfjs = await import("pdfjs-dist");
      pdfjs.GlobalWorkerOptions.workerSrc = pdfWorkerUrl;
      loadingTask = pdfjs.getDocument({ url });
      const document = await loadingTask.promise;
      if (!cancelled) setPdf(document);
    };

    load().catch((error) => {
      console.error("Dark PDF load failed", error);
      if (!cancelled) setStatus("error");
    });

    return () => {
      cancelled = true;
      void loadingTask?.destroy();
    };
  }, [url]);

  useEffect(() => {
    const container = containerRef.current;
    if (!pdf || !container || width <= 0) return;

    let cancelled = false;
    container.replaceChildren();

    const renderPages = async () => {
      const devicePixelRatio = Math.min(window.devicePixelRatio || 1, 2);

      for (let pageNumber = 1; pageNumber <= pdf.numPages; pageNumber++) {
        const page = await pdf.getPage(pageNumber);
        if (cancelled) return;

        const base = page.getViewport({ scale: 1 });
        const viewport = page.getViewport({ scale: (width / base.width) * devicePixelRatio });
        const canvas = document.createElement("canvas");
        canvas.width = Math.floor(viewport.width);
        canvas.height = Math.floor(viewport.height);
        canvas.style.width = `${width}px`;
        canvas.style.height = `${(width / base.width) * base.height}px`;
        canvas.className = "mx-auto mb-4 block";

        const context = canvas.getContext("2d");
        if (!context) throw new Error("Canvas 2D context unavailable");
        await page.render({ canvasContext: context, canvas, viewport }).promise;
        if (cancelled) return;

        const imageData = context.getImageData(0, 0, canvas.width, canvas.height);
        flipLightnessKeepHue(imageData);
        context.putImageData(imageData, 0, 0);
        container.appendChild(canvas);
      }
      setStatus("ready");
    };

    renderPages().catch((error) => {
      console.error("Dark PDF render failed", error);
      if (!cancelled) setStatus("error");
    });

    return () => {
      cancelled = true;
    };
  }, [pdf, width]);

  return (
    <div className="w-full">
      <div ref={containerRef} className="w-full" />
      {status === "loading" && (
        <p className="py-6 text-center text-sm text-gray-400">Preparing dark view…</p>
      )}
      {status === "error" && (
        <p className="py-6 text-center text-sm text-gray-400">
          The dark view could not load this PDF. Switch back to the light view or use Open PDF.
        </p>
      )}
    </div>
  );
};

export default DarkPdfPages;
