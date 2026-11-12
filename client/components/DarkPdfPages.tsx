import { useEffect, useRef, useState } from "react";
import type { PDFDocumentLoadingTask, PDFDocumentProxy } from "pdfjs-dist";
import pdfWorkerUrl from "pdfjs-dist/build/pdf.worker.min.mjs?url";

const NEUTRAL_SPREAD = 12;
const TRANSPARENT = "rgba(0, 0, 0, 0)";

const mapNeutralPixels = (imageData: ImageData, map: (channel: number) => number) => {
  const { data } = imageData;
  for (let i = 0; i < data.length; i += 4) {
    const r = data[i];
    const g = data[i + 1];
    const b = data[i + 2];
    if (data[i + 3] === 0 || Math.max(r, g, b) - Math.min(r, g, b) > NEUTRAL_SPREAD) continue;
    data[i] = map(r);
    data[i + 1] = map(g);
    data[i + 2] = map(b);
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
      const { OPS } = await import("pdfjs-dist");
      const devicePixelRatio = Math.min(window.devicePixelRatio || 1, 2);

      const textOps = new Set([
        OPS.showText,
        OPS.showSpacedText,
        OPS.nextLineShowText,
        OPS.nextLineSetSpacingShowText,
      ]);
      const drawingOps = new Set([
        OPS.moveTo,
        OPS.lineTo,
        OPS.curveTo,
        OPS.curveTo2,
        OPS.curveTo3,
        OPS.rectangle,
        OPS.closePath,
        OPS.constructPath,
        OPS.rawFillPath,
        OPS.endPath,
        OPS.clip,
        OPS.eoClip,
        OPS.stroke,
        OPS.closeStroke,
        OPS.fill,
        OPS.eoFill,
        OPS.fillStroke,
        OPS.eoFillStroke,
        OPS.closeFillStroke,
        OPS.closeEOFillStroke,
        OPS.shadingFill,
        OPS.beginInlineImage,
        OPS.beginImageData,
        OPS.endInlineImage,
        OPS.paintImageMaskXObject,
        OPS.paintImageMaskXObjectGroup,
        OPS.paintImageXObject,
        OPS.paintInlineImageXObject,
        OPS.paintInlineImageXObjectGroup,
        OPS.paintImageXObjectRepeat,
        OPS.paintImageMaskXObjectRepeat,
        OPS.paintSolidColorImageMask,
      ]);
      const withoutText = (index: number, list: { fnArray: number[] }) =>
        !textOps.has(list.fnArray[index]);
      const textOnly = (index: number, list: { fnArray: number[] }) =>
        !drawingOps.has(list.fnArray[index]);

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
        const layer = document.createElement("canvas");
        layer.width = canvas.width;
        layer.height = canvas.height;
        const layerContext = layer.getContext("2d", { willReadFrequently: true });
        if (!context || !layerContext) throw new Error("Canvas 2D context unavailable");

        context.fillStyle = "#000000";
        context.fillRect(0, 0, canvas.width, canvas.height);

        await page.render({
          canvasContext: layerContext,
          canvas: layer,
          viewport,
          background: TRANSPARENT,
          operationsFilter: withoutText,
        }).promise;
        if (cancelled) return;
        const graphics = layerContext.getImageData(0, 0, layer.width, layer.height);
        mapNeutralPixels(graphics, (channel) => 255 - channel);
        layerContext.putImageData(graphics, 0, 0);
        context.drawImage(layer, 0, 0);

        layerContext.clearRect(0, 0, layer.width, layer.height);
        await page.render({
          canvasContext: layerContext,
          canvas: layer,
          viewport,
          background: TRANSPARENT,
          operationsFilter: textOnly,
        }).promise;
        if (cancelled) return;
        const text = layerContext.getImageData(0, 0, layer.width, layer.height);
        mapNeutralPixels(text, () => 255);
        layerContext.putImageData(text, 0, 0);
        context.drawImage(layer, 0, 0);

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
