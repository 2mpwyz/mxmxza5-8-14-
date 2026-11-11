import { toast } from "../hooks/use-toast";
import { supabase } from "./supabase";

export const downloadAttachment = async (attachmentId: string): Promise<void> => {
  try {
    const { data: { session } } = await supabase.auth.getSession();
    if (!session?.access_token) throw new Error("Authentication is required");

    const response = await fetch("https://us-central1-speshio.cloudfunctions.net/createAttachmentDownloadUrl", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        apikey: import.meta.env.VITE_SUPABASE_ANON_KEY,
        Authorization: `Bearer ${session.access_token}`,
      },
      body: JSON.stringify({ attachmentId }),
    });
    if (!response.ok) throw new Error("Download request failed");

    const { url } = await response.json() as { url: string };
    window.location.assign(url);
  } catch {
    toast({
      title: "Download failed",
      description: "Unable to download this attachment.",
      variant: "destructive",
    });
  }
};
