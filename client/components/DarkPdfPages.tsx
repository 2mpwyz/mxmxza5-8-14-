import { useEffect, useRef, useState } from "react";
import type { PDFDocumentLoadingTask, PDFDocumentProxy } from "pdfjs-dist";
import pdfWorkerUrl from "pdfjs-dist/build/pdf.worker.min.mjs?url";

const NEUTRAL_CHROMA_LIMIT = 24;

const invertNeutralPixels = (imageData: ImageData) => {
  const { data } = imageData;
  for (let i = 0; i < data.length; i += 4) {
    const r = data[i];
    const g = data[i + 1];
    const b = data[i + 2];
    if (Math.max(r, g, b) - Math.min(r, g, b) > NEUTRAL_CHROMA_LIMIT) continue;
    data[i] = 255 - r;
    data[i + 1] = 255 - g;
    data[i + 2] = 255 - b;
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
        invertNeutralPixels(imageData);
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
