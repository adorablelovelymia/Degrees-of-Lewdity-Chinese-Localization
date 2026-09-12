#include <gtk/gtk.h>
#include <webkit2/webkit2.h>
#include <libsoup/soup.h>
#include <gio/gio.h>
#include <glib/gstdio.h>
#include <glib-unix.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    gchar *base_dir;
    gchar *base_real;
    gchar *index_name;
} ServerCtx;

static void
server_ctx_free (gpointer data)
{
    ServerCtx *ctx = data;
    g_free (ctx->base_dir);
    g_free (ctx->base_real);
    g_free (ctx->index_name);
    g_free (ctx);
}

static void
server_cb (SoupServer *server, SoupServerMessage *msg, const char *path,
           GHashTable *query, gpointer user_data)
{
    ServerCtx *ctx = user_data;
    const gchar *method = soup_server_message_get_method (msg);

    if (g_strcmp0 (method, "GET") != 0 && g_strcmp0 (method, "HEAD") != 0) {
        soup_server_message_set_status (msg, SOUP_STATUS_METHOD_NOT_ALLOWED, NULL);
        return;
    }

    gchar *decoded = g_uri_unescape_string (path, NULL);
    if (decoded == NULL) {
        soup_server_message_set_status (msg, SOUP_STATUS_BAD_REQUEST, NULL);
        return;
    }

    const gchar *rel = decoded;
    while (*rel == '/')
        rel++;

    gchar *full = (*rel == '\0')
        ? g_build_filename (ctx->base_dir, ctx->index_name, NULL)
        : g_build_filename (ctx->base_dir, rel, NULL);

    gchar *real = realpath (full, NULL);
    g_free (full);
    g_free (decoded);

    if (real == NULL) {
        soup_server_message_set_status (msg, SOUP_STATUS_NOT_FOUND, NULL);
        return;
    }

    if (ctx->base_real == NULL) {
        g_free (real);
        soup_server_message_set_status (msg, SOUP_STATUS_NOT_FOUND, NULL);
        return;
    }

    gsize base_len = strlen (ctx->base_real);
    if (strncmp (real, ctx->base_real, base_len) != 0 ||
        (real[base_len] != G_DIR_SEPARATOR && real[base_len] != '\0')) {
        g_free (real);
        soup_server_message_set_status (msg, SOUP_STATUS_NOT_FOUND, NULL);
        return;
    }

    GError *error = NULL;
    GMappedFile *map = g_mapped_file_new (real, FALSE, &error);
    if (map == NULL) {
        g_clear_error (&error);
        g_free (real);
        soup_server_message_set_status (msg, SOUP_STATUS_NOT_FOUND, NULL);
        return;
    }

    gchar *content_type;
    if (g_str_has_suffix (real, ".html") || g_str_has_suffix (real, ".htm")) {
        content_type = g_strdup ("text/html; charset=utf-8");
    }
    else {
        gchar *guessed = g_content_type_guess (real, NULL, 0, NULL);
        content_type = g_content_type_get_mime_type (guessed);
        g_free (guessed);
    }
    g_free (real);

    SoupMessageHeaders *headers = soup_server_message_get_response_headers (msg);
    soup_message_headers_replace (headers, "Cache-Control", "no-cache");

    soup_server_message_set_status (msg, SOUP_STATUS_OK, NULL);
    soup_server_message_set_response (msg, content_type,
                                      SOUP_MEMORY_STATIC,
                                      g_mapped_file_get_contents (map),
                                      g_mapped_file_get_length (map));
    g_object_set_data_full (G_OBJECT (msg), "dol-mapped-file", map,
                            (GDestroyNotify) g_mapped_file_unref);
    g_free (content_type);
}

static SoupServer *
server_start (const gchar *base_dir, const gchar *index_name, guint *port_out)
{
    for (guint port = 8264; port <= 8284; port++) {
        GError *error = NULL;
        SoupServer *server = soup_server_new ("server-header", "dol-launcher", NULL);
        ServerCtx *ctx = g_new0 (ServerCtx, 1);
        ctx->base_dir = g_strdup (base_dir);
        ctx->base_real = realpath (base_dir, NULL);
        ctx->index_name = g_strdup (index_name);
        soup_server_add_handler (server, NULL, server_cb, ctx, server_ctx_free);
        if (soup_server_listen_local (server, port, SOUP_SERVER_LISTEN_IPV4_ONLY, &error)) {
            *port_out = port;
            return server;
        }
        g_clear_error (&error);
        g_object_unref (server);
    }
    return NULL;
}

static gboolean
on_view_close (WebKitWebView *view, gpointer data)
{
    gtk_window_close (GTK_WINDOW (data));
    return TRUE;
}

static void
on_web_process_terminated (WebKitWebView *view, WebKitWebProcessTerminationReason reason, gpointer data)
{
    const gchar *text = (reason == WEBKIT_WEB_PROCESS_CRASHED)
        ? "渲染进程崩溃，游戏已退出。"
        : "渲染进程被系统终止（可能内存不足），游戏已退出。";
    GtkWidget *dialog = gtk_message_dialog_new (
        GTK_WINDOW (data), GTK_DIALOG_MODAL, GTK_MESSAGE_ERROR, GTK_BUTTONS_CLOSE,
        "%s", text);
    gtk_dialog_run (GTK_DIALOG (dialog));
    gtk_widget_destroy (dialog);
    gtk_window_close (GTK_WINDOW (data));
}

static gboolean
on_signal (gpointer data)
{
    gtk_main_quit ();
    return G_SOURCE_REMOVE;
}

int
main (int argc, char **argv)
{
    const gchar *game_arg = (argc > 1) ? argv[1] : "Degrees of Lewdity.html";
    gchar *game_path = g_canonicalize_filename (game_arg, NULL);
    gchar *base_dir = g_path_get_dirname (game_path);
    gchar *index_name = g_path_get_basename (game_path);

    gtk_init (&argc, &argv);

    if (!g_file_test (game_path, G_FILE_TEST_IS_REGULAR)) {
        GtkWidget *dialog = gtk_message_dialog_new (
            NULL, GTK_DIALOG_MODAL, GTK_MESSAGE_ERROR, GTK_BUTTONS_CLOSE,
            "找不到游戏文件：%s", game_path);
        gtk_dialog_run (GTK_DIALOG (dialog));
        gtk_widget_destroy (dialog);
        return 1;
    }

    gchar *data_dir = g_build_filename (base_dir, ".dol-data", NULL);
    gchar *cache_dir = g_build_filename (data_dir, "cache", NULL);
    g_mkdir_with_parents (cache_dir, 0700);

    guint port = 0;
    SoupServer *server = server_start (base_dir, index_name, &port);
    if (server == NULL) {
        GtkWidget *dialog = gtk_message_dialog_new (
            NULL, GTK_DIALOG_MODAL, GTK_MESSAGE_ERROR, GTK_BUTTONS_CLOSE,
            "%s", "无法在 127.0.0.1 的 8264-8284 端口上启动本地服务。");
        gtk_dialog_run (GTK_DIALOG (dialog));
        gtk_widget_destroy (dialog);
        return 1;
    }

    WebKitWebsiteDataManager *manager = webkit_website_data_manager_new (
        "base-data-directory", data_dir,
        "base-cache-directory", cache_dir,
        NULL);
    WebKitWebContext *context = webkit_web_context_new_with_website_data_manager (manager);
    g_object_unref (manager);

    GtkWidget *window = gtk_window_new (GTK_WINDOW_TOPLEVEL);
    gtk_window_set_title (GTK_WINDOW (window), "Degrees of Lewdity");
    gtk_window_set_default_size (GTK_WINDOW (window), 1280, 800);

    gchar *icon_path = g_build_filename (base_dir, "dol-icon.png", NULL);
    if (g_file_test (icon_path, G_FILE_TEST_IS_REGULAR)) {
        gtk_window_set_default_icon_from_file (icon_path, NULL);
        gtk_window_set_icon_from_file (GTK_WINDOW (window), icon_path, NULL);
    }
    g_free (icon_path);

    GtkWidget *view = webkit_web_view_new_with_context (context);
    g_object_unref (context);

    WebKitSettings *settings = webkit_web_view_get_settings (WEBKIT_WEB_VIEW (view));
    if (g_getenv ("DOL_SOFTWARE_RENDER") != NULL)
        webkit_settings_set_hardware_acceleration_policy (settings, WEBKIT_HARDWARE_ACCELERATION_POLICY_NEVER);
    webkit_settings_set_enable_page_cache (settings, FALSE);
    webkit_settings_set_enable_developer_extras (settings, FALSE);

    g_signal_connect (window, "destroy", G_CALLBACK (gtk_main_quit), NULL);
    g_signal_connect (view, "close", G_CALLBACK (on_view_close), window);
    g_signal_connect (view, "web-process-terminated",
                      G_CALLBACK (on_web_process_terminated), window);

    gtk_container_add (GTK_CONTAINER (window), view);
    gtk_widget_show_all (window);

    gchar *escaped = g_uri_escape_string (index_name, NULL, FALSE);
    gchar *url = g_strdup_printf ("http://127.0.0.1:%u/%s", port, escaped);
    webkit_web_view_load_uri (WEBKIT_WEB_VIEW (view), url);
    g_free (url);
    g_free (escaped);

    g_unix_signal_add (SIGINT, on_signal, NULL);
    g_unix_signal_add (SIGTERM, on_signal, NULL);

    gtk_main ();

    g_object_unref (server);
    g_free (data_dir);
    g_free (cache_dir);
    g_free (base_dir);
    g_free (index_name);
    g_free (game_path);
    return 0;
}
