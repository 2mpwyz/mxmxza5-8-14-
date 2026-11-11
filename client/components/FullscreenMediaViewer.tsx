import React, { useEffect, useRef, useState } from "react";
import { ChevronLeft, ChevronRight, Download, Maximize, Minimize, X, ZoomIn, ZoomOut } from "lucide-react";

export interface FullscreenMediaItem {
  url: string;
  type: string;
  name: string;
  description?: string | null;
  fileSize?: number;
  footerLabel?: string;
}

interface FullscreenMediaViewerProps {
  items: FullscreenMediaItem[];
  selectedIndex: number | null;
  onSelectedIndexChange: (index: number | null) => void;
}

const ZOOM_STEPS = [1, 1.25, 1.5, 2, 2.5, 3];

const isPdf = (filename: string): boolean => filename.toLowerCase().endsWith(".pdf");

const FullscreenMediaViewer: React.FC<FullscreenMediaViewerProps> = ({
  items,
  selectedIndex,
  onSelectedIndexChange,
}) => {
  const rootRef = useRef<HTMLDivElement>(null);
  const [zoomIndex, setZoomIndex] = useState(0);
  const [isFullscreen, setIsFullscreen] = useState(false);
  const [controlsVisible, setControlsVisible] = useState(true);
  const hideTimerRef = useRef<number | undefined>(undefined);
  const mediaRef = useRef<HTMLDivElement>(null);
  const [available, setAvailable] = useState<{ width: number; height: number } | null>(null);
  const [naturalSize, setNaturalSize] = useState<{ url: string; width: number; height: number } | null>(null);

  useEffect(() => {
    setZoomIndex(0);
  }, [selectedIndex]);

  useEffect(() => {
    if (selectedIndex === null) setIsFullscreen(false);
  }, [selectedIndex]);

  useEffect(() => {
    const handleFullscreenChange = () => {
      if (!document.fullscreenElement) setIsFullscreen(false);
    };
    document.addEventListener("fullscreenchange", handleFullscreenChange);
    return () => document.removeEventListener("fullscreenchange", handleFullscreenChange);
  }, []);

  useEffect(() => {
    if (!isFullscreen) {
      setControlsVisible(true);
      return;
    }

    const root = rootRef.current;
    const scheduleHide = () => {
      window.clearTimeout(hideTimerRef.current);
      hideTimerRef.current = window.setTimeout(() => setControlsVisible(false), 2500);
    };
    const revealControls = () => {
      setControlsVisible(true);
      scheduleHide();
    };

    scheduleHide();
    root?.addEventListener("pointermove", revealControls);
    root?.addEventListener("pointerdown", revealControls);
    return () => {
      root?.removeEventListener("pointermove", revealControls);
      root?.removeEventListener("pointerdown", revealControls);
      window.clearTimeout(hideTimerRef.current);
    };
  }, [isFullscreen]);

  const isOpen = selectedIndex !== null;
  useEffect(() => {
    const el = mediaRef.current;
    if (!el) return;

    const measure = () => {
      const style = getComputedStyle(el);
      setAvailable({
        width: el.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight),
        height: el.clientHeight - parseFloat(style.paddingTop) - parseFloat(style.paddingBottom),
      });
    };

    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(el);
    return () => observer.disconnect();
  }, [isOpen]);

  const selectedItem = selectedIndex === null ? null : items[selectedIndex];

  if (!selectedItem) return null;

  const isImage = selectedItem.type === "image";
  const isTouchPrimary = window.matchMedia("(pointer: coarse)").matches;
  const zoom = ZOOM_STEPS[zoomIndex];
  const canZoomOut = zoomIndex > 0;
  const canZoomIn = zoomIndex < ZOOM_STEPS.length - 1;
  const imageDisplaySize =
    naturalSize && naturalSize.url === selectedItem.url && available
      ? (() => {
          const fit = Math.min(
            available.width / naturalSize.width,
            available.height / naturalSize.height,
            1,
          );
          return {
            width: naturalSize.width * fit * zoom,
            height: naturalSize.height * fit * zoom,
          };
        })()
      : null;
  const chromeClass = `transition-opacity duration-300 ${
    isFullscreen && !controlsVisible ? "pointer-events-none opacity-0" : "opacity-100"
  }`;

  const handlePrev = () => {
    if (selectedIndex !== null && selectedIndex > 0) {
      onSelectedIndexChange(selectedIndex - 1);
    }
  };

  const handleNext = () => {
    if (selectedIndex !== null && selectedIndex < items.length - 1) {
      onSelectedIndexChange(selectedIndex + 1);
    }
  };

  const toggleFullscreen = async () => {
    if (isFullscreen) {
      setIsFullscreen(false);
      if (document.fullscreenElement) {
        await document.exitFullscreen().catch((error) => console.error("Exit fullscreen failed", error));
      }
      return;
    }
    setIsFullscreen(true);
    await rootRef.current?.requestFullscreen().catch((error) => console.error("Enter fullscreen failed", error));
  };

  return (
    <div ref={rootRef} className="fixed inset-0 z-50 flex flex-col bg-black/95">
      <div
        className={`flex items-center justify-between p-4 ${chromeClass} ${
          isFullscreen ? "absolute inset-x-0 top-0 z-20" : "border-b border-gray-700 bg-black"
        }`}
      >
        {!isFullscreen && <div className="flex-1" />}
        <div className="flex items-center gap-2">
          {isImage && (
            <>
              <button
                onClick={() => setZoomIndex((index) => index - 1)}
                disabled={!canZoomOut}
                aria-label="Zoom out"
                className="rounded-lg p-2 transition-colors hover:bg-gray-700 disabled:cursor-not-allowed disabled:opacity-50"
              >
                <ZoomOut className="h-5 w-5 text-white" />
              </button>
              <button
                onClick={() => setZoomIndex(0)}
                aria-label="Reset zoom"
                className="w-16 rounded-lg px-2 py-1 text-center text-sm text-white transition-colors hover:bg-gray-700"
              >
                {Math.round(zoom * 100)}%
              </button>
              <button
                onClick={() => setZoomIndex((index) => index + 1)}
                disabled={!canZoomIn}
                aria-label="Zoom in"
                className="rounded-lg p-2 transition-colors hover:bg-gray-700 disabled:cursor-not-allowed disabled:opacity-50"
              >
                <ZoomIn className="h-5 w-5 text-white" />
              </button>
            </>
          )}
          <button
            onClick={toggleFullscreen}
            aria-label={isFullscreen ? "Exit full screen" : "Enter full screen"}
            className="rounded-lg p-2 transition-colors hover:bg-gray-700"
          >
            {isFullscreen ? (
              <Minimize className="h-5 w-5 text-white" />
            ) : (
              <Maximize className="h-5 w-5 text-white" />
            )}
          </button>
        </div>
        <div className="flex flex-1 justify-end">
          <button
            onClick={() => onSelectedIndexChange(null)}
            aria-label="Close media viewer"
            className="rounded-lg p-2 transition-colors hover:bg-gray-700"
          >
            <X className="h-6 w-6 text-white" />
          </button>
        </div>
      </div>

      <div className="relative flex min-h-0 flex-1">
        <div ref={mediaRef} className={`absolute inset-0 flex overflow-auto px-16 ${isFullscreen ? "" : "py-4"}`}>
          {isImage ? (
            <img
              src={selectedItem.url}
              alt={selectedItem.description || selectedItem.name}
              onLoad={(event) =>
                setNaturalSize({
                  url: selectedItem.url,
                  width: event.currentTarget.naturalWidth,
                  height: event.currentTarget.naturalHeight,
                })
              }
              className={imageDisplaySize ? "m-auto max-w-none" : "m-auto max-h-full max-w-full object-contain"}
              style={imageDisplaySize ?? undefined}
            />
          ) : selectedItem.type === "video" ? (
            <video
              src={selectedItem.url}
              controls
              autoPlay
              className="m-auto max-h-full max-w-full"
            />
          ) : (
            <div className="flex h-full w-full flex-col items-center justify-center">
              {isPdf(selectedItem.name) && isTouchPrimary ? (
                <div className="flex flex-col items-center gap-4 px-6 text-center">
                  <p className="text-lg text-white">{selectedItem.name}</p>
                  <a
                    href={selectedItem.url}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="inline-flex items-center gap-2 rounded-lg bg-sheraton-gold px-6 py-3 font-semibold text-sheraton-navy transition-all hover:bg-opacity-90"
                  >
                    <Download className="h-4 w-4" />
                    Open PDF
                  </a>
                  <a
                    href={selectedItem.url}
                    download={selectedItem.name}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="inline-flex items-center gap-2 rounded-lg px-6 py-3 text-sheraton-gold transition-colors hover:text-white"
                  >
                    <Download className="h-4 w-4" />
                    Download
                  </a>
                </div>
              ) : isPdf(selectedItem.name) ? (
                <>
                  <iframe
                    src={selectedItem.url}
                    className="h-full w-full border-0"
                    title={selectedItem.name}
                  />
                  <div className="absolute bottom-4 left-1/2 -translate-x-1/2 rounded bg-black/80 px-4 py-2">
                    <a
                      href={selectedItem.url}
                      download={selectedItem.name}
                      target="_blank"
                      rel="noopener noreferrer"
                      className="inline-flex items-center gap-2 text-sheraton-gold transition-colors hover:text-white"
                    >
                      <Download className="h-4 w-4" />
                      Open PDF
                    </a>
                  </div>
                </>
              ) : (
                <div className="text-center">
                  <div className="mb-4 text-6xl">📄</div>
                  <p className="mb-2 text-lg text-white">{selectedItem.name}</p>
                  {!!selectedItem.fileSize && (
                    <p className="mb-6 text-gray-400">
                      {(selectedItem.fileSize / 1024 / 1024).toFixed(2)} MB
                    </p>
                  )}
                  <a
                    href={selectedItem.url}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="inline-flex items-center gap-2 rounded-lg bg-sheraton-gold px-6 py-3 font-semibold text-sheraton-navy transition-all hover:bg-opacity-90"
                  >
                    <Download className="h-4 w-4" />
                    Download
                  </a>
                </div>
              )}
            </div>
          )}
        </div>

        <div className={`absolute left-4 top-1/2 z-10 -translate-y-1/2 ${chromeClass}`}>
          <span className="absolute bottom-full left-1/2 mb-6 -translate-x-1/2 whitespace-nowrap text-sm text-gray-400">
            {selectedItem.footerLabel || `${selectedIndex + 1} / ${items.length}`}
          </span>
          <button
            onClick={handlePrev}
            disabled={selectedIndex === 0}
            aria-label="Previous attachment"
            className="rounded-lg p-2 transition-colors hover:bg-gray-700 disabled:cursor-not-allowed disabled:opacity-50"
          >
            <ChevronLeft className="h-6 w-6 text-white" />
          </button>
        </div>
        <div className={`absolute right-4 top-1/2 z-10 -translate-y-1/2 ${chromeClass}`}>
          <span className="absolute bottom-full left-1/2 mb-6 -translate-x-1/2 whitespace-nowrap text-sm text-gray-400">
            {selectedItem.footerLabel || `${selectedIndex + 1} / ${items.length}`}
          </span>
          <button
            onClick={handleNext}
            disabled={selectedIndex === items.length - 1}
            aria-label="Next attachment"
            className="rounded-lg p-2 transition-colors hover:bg-gray-700 disabled:cursor-not-allowed disabled:opacity-50"
          >
            <ChevronRight className="h-6 w-6 text-white" />
          </button>
        </div>
      </div>

      <div
        className={`flex items-center justify-between gap-4 p-4 ${chromeClass} ${
          isFullscreen ? "absolute inset-x-0 bottom-0 z-20" : "border-t border-gray-700 bg-black"
        }`}
      >
        <div className="min-w-0 flex-1">
          <p className="truncate font-medium text-white">{selectedItem.name}</p>
          {selectedItem.description && (
            <p className="truncate text-sm text-gray-400">{selectedItem.description}</p>
          )}
        </div>
        <span className="shrink-0 text-sm font-medium text-white">{selectedItem.type.toUpperCase()}</span>
      </div>
    </div>
  );
};

export default FullscreenMediaViewer;
