import { useEffect, useRef, useState } from "react";
import type { PDFDocumentLoadingTask, PDFDocumentProxy, PDFPageProxy } from "pdfjs-dist";
import pdfWorkerUrl from "pdfjs-dist/build/pdf.worker.min.mjs?url";

const NEUTRAL_SPREAD = 12;
const MAX_CANVAS_PIXELS = 4_000_000;
const RENDER_MARGIN_PX = 1000;
const RESIZE_DEBOUNCE_MS = 150;
const TRANSPARENT = "rgba(0, 0, 0, 0)";

type OperationFilter = (index: number, list: { fnArray: number[] }) => boolean;
type OperationFilters = { withoutText: OperationFilter; textOnly: OperationFilter };

let operationFilters: Promise<OperationFilters> | null = null;

const getOperationFilters = () => {
  if (!operationFilters) {
    operationFilters = import("pdfjs-dist").then(({ OPS }) => {
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
      return {
        withoutText: (index, list) => !textOps.has(list.fnArray[index]),
        textOnly: (index, list) => !drawingOps.has(list.fnArray[index]),
      };
    });
  }
  return operationFilters;
};

const isNeutral = (data: Uint8ClampedArray, index: number) =>
  Math.max(data[index], data[index + 1], data[index + 2]) - Math.min(data[index], data[index + 1], data[index + 2]) <=
  NEUTRAL_SPREAD;

const invertNeutralPixels = (imageData: ImageData) => {
  const { data } = imageData;
  for (let i = 0; i < data.length; i += 4) {
    if (data[i + 3] === 0 || !isNeutral(data, i)) continue;
    data[i] = 255 - data[i];
    data[i + 1] = 255 - data[i + 1];
    data[i + 2] = 255 - data[i + 2];
  }
};

const setNeutralInkForBackdrop = (ink: ImageData, backdrop: ImageData) => {
  const { data } = ink;
  const background = backdrop.data;
  for (let i = 0; i < data.length; i += 4) {
    if (data[i + 3] === 0 || !isNeutral(data, i)) continue;
    const luminance = 0.299 * background[i] + 0.587 * background[i + 1] + 0.114 * background[i + 2];
    const value = luminance > 128 ? 0 : 255;
    data[i] = value;
    data[i + 1] = value;
    data[i + 2] = value;
  }
};

type PageSlot = {
  page: PDFPageProxy;
  element: HTMLDivElement;
  canvas: HTMLCanvasElement | null;
  visible: boolean;
  pending: boolean;
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
    let observer: IntersectionObserver | null = null;
    const slots = new Map<Element, PageSlot>();

    const releaseSlot = (slot: PageSlot) => {
      slot.visible = false;
      if (!slot.canvas) return;
      slot.canvas.width = 0;
      slot.canvas.height = 0;
      slot.canvas.remove();
      slot.canvas = null;
    };

    const drawPage = async (slot: PageSlot, filters: OperationFilters) => {
      const base = slot.page.getViewport({ scale: 1 });
      const devicePixelRatio = Math.min(window.devicePixelRatio || 1, 2);
      const scale = Math.min(
        (width / base.width) * devicePixelRatio,
        Math.sqrt(MAX_CANVAS_PIXELS / (base.width * base.height)),
      );
      const viewport = slot.page.getViewport({ scale });

      const canvas = document.createElement("canvas");
      canvas.width = Math.floor(viewport.width);
      canvas.height = Math.floor(viewport.height);
      canvas.style.width = `${width}px`;
      canvas.style.height = `${(width / base.width) * base.height}px`;
      const context = canvas.getContext("2d");
      const layer = document.createElement("canvas");
      layer.width = canvas.width;
      layer.height = canvas.height;
      const layerContext = layer.getContext("2d", { willReadFrequently: true });
      if (!context || !layerContext) throw new Error("Canvas 2D context unavailable");

      context.fillStyle = "#000000";
      context.fillRect(0, 0, canvas.width, canvas.height);

      await slot.page.render({
        canvasContext: layerContext,
        canvas: layer,
        viewport,
        background: TRANSPARENT,
        operationsFilter: filters.withoutText,
      }).promise;
      if (cancelled || !slot.visible) return null;
      const graphics = layerContext.getImageData(0, 0, layer.width, layer.height);
      invertNeutralPixels(graphics);
      layerContext.putImageData(graphics, 0, 0);
      context.drawImage(layer, 0, 0);

      layerContext.clearRect(0, 0, layer.width, layer.height);
      await slot.page.render({
        canvasContext: layerContext,
        canvas: layer,
        viewport,
        background: TRANSPARENT,
        operationsFilter: filters.textOnly,
      }).promise;
      if (cancelled || !slot.visible) return null;
      const text = layerContext.getImageData(0, 0, layer.width, layer.height);
      setNeutralInkForBackdrop(text, graphics);
      layerContext.putImageData(text, 0, 0);
      context.drawImage(layer, 0, 0);

      return canvas;
    };

    const renderSlot = async (slot: PageSlot) => {
      if (slot.canvas || slot.pending || !slot.visible) return;
      slot.pending = true;
      try {
        const filters = await getOperationFilters();
        const canvas = await drawPage(slot, filters);
        if (canvas && slot.visible && !cancelled) {
          slot.element.replaceChildren(canvas);
          slot.canvas = canvas;
        }
      } catch (error) {
        console.error("Dark PDF render failed", error);
        if (!cancelled) setStatus("error");
        return;
      } finally {
        slot.pending = false;
      }
      if (!cancelled && slot.visible && !slot.canvas) void renderSlot(slot);
    };

    const handleIntersections = (entries: IntersectionObserverEntry[]) => {
      for (const entry of entries) {
        const slot = slots.get(entry.target);
        if (!slot) continue;
        if (entry.isIntersecting) {
          slot.visible = true;
          void renderSlot(slot);
        } else {
          releaseSlot(slot);
        }
      }
    };

    const buildPages = async () => {
      const pages = await Promise.all(
        Array.from({ length: pdf.numPages }, (_, index) => pdf.getPage(index + 1)),
      );
      if (cancelled) return;
      container.replaceChildren();
      observer = new IntersectionObserver(handleIntersections, {
        rootMargin: `${RENDER_MARGIN_PX}px 0px`,
      });
      for (const page of pages) {
        const base = page.getViewport({ scale: 1 });
        const element = document.createElement("div");
        element.className = "mx-auto mb-4";
        element.style.width = `${width}px`;
        element.style.height = `${(width / base.width) * base.height}px`;
        slots.set(element, { page, element, canvas: null, visible: false, pending: false });
        container.appendChild(element);
        observer.observe(element);
      }
      setStatus("ready");
    };

    const timer = window.setTimeout(() => {
      buildPages().catch((error) => {
        console.error("Dark PDF render failed", error);
        if (!cancelled) setStatus("error");
      });
    }, RESIZE_DEBOUNCE_MS);

    return () => {
      cancelled = true;
      window.clearTimeout(timer);
      observer?.disconnect();
      slots.forEach(releaseSlot);
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
