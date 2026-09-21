#include "Bridge.h"

#include <QtWebEngineQuick/qtwebenginequickglobal.h>

#include <QCommandLineParser>
#include <QDir>
#include <QGuiApplication>
#include <QLocalServer>
#include <QLocalSocket>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QStandardPaths>
#include <QTextStream>

#ifndef OMATEAMS_VERSION
#define OMATEAMS_VERSION "dev"
#endif

// The host exists for two reasons plain QML cannot cover: QtWebEngine must be
// initialised before the application object exists (Quickshell does neither
// that nor passes argv on to Chromium, which is why the WebEngine cannot run
// inside omarchy-shell), and the window needs its own Wayland app id so
// Hyprland rules and the bar widget can find it.

namespace {

QString socketPath()
{
    QString dir = QStandardPaths::writableLocation(QStandardPaths::RuntimeLocation);
    if (dir.isEmpty())
        dir = QDir::tempPath();
    return dir + QStringLiteral("/omateams.sock");
}

// Forward a command to a running instance. Returns true when one answered.
bool sendToRunning(const QString &command, QString *reply)
{
    QLocalSocket socket;
    socket.connectToServer(socketPath());
    if (!socket.waitForConnected(300))
        return false;
    socket.write(command.toUtf8());
    socket.write("\n");
    socket.flush();
    if (socket.waitForReadyRead(3000))
        *reply = QString::fromUtf8(socket.readAll()).trimmed();
    socket.disconnectFromServer();
    return true;
}

} // namespace

int main(int argc, char *argv[])
{
    // Screen sharing on Wayland goes through PipeWire; Chromium only asks the
    // portal for it when the feature is switched on.
    QByteArray flags = qgetenv("QTWEBENGINE_CHROMIUM_FLAGS");
    if (!flags.contains("WebRTCPipeWireCapturer"))
        flags += " --enable-features=WebRTCPipeWireCapturer";
    qputenv("QTWEBENGINE_CHROMIUM_FLAGS", flags.trimmed());

    for (int i = 1; i < argc; ++i) {
        if (qstrcmp(argv[i], "--debug-port") == 0 && i + 1 < argc)
            qputenv("QTWEBENGINE_REMOTE_DEBUGGING", argv[i + 1]);
    }

    QtWebEngineQuick::initialize();
    QGuiApplication app(argc, argv);
    app.setApplicationName(QStringLiteral("omateams"));
    app.setOrganizationName(QStringLiteral("omateams"));
    app.setApplicationVersion(QStringLiteral(OMATEAMS_VERSION));
    app.setDesktopFileName(QStringLiteral("omateams"));

    QCommandLineParser parser;
    parser.setApplicationDescription(QStringLiteral(
        "Microsoft Teams in an Omarchy-themed window.\n\n"
        "Commands (sent to the running instance, or start one):\n"
        "  start | show | hide | toggle | quit | status | reload-theme"));
    parser.addHelpOption();
    parser.addVersionOption();
    parser.addPositionalArgument(QStringLiteral("command"), QStringLiteral("start, show, hide, toggle, quit, status or reload-theme"), QStringLiteral("[command]"));
    QCommandLineOption hiddenOption(QStringLiteral("hidden"), QStringLiteral("Start without showing the window."));
    QCommandLineOption urlOption(QStringLiteral("url"), QStringLiteral("Teams URL to open."), QStringLiteral("url"));
    QCommandLineOption debugOption(QStringLiteral("debug-port"), QStringLiteral("Expose the Chromium remote debugging port."), QStringLiteral("port"));
    parser.addOption(hiddenOption);
    parser.addOption(urlOption);
    parser.addOption(debugOption);
    parser.process(app);

    // Bare `omateams` opens the window; `omateams --hidden` (the autostart
    // path) only makes sure an instance exists and never brings it forward.
    const QStringList positional = parser.positionalArguments();
    const QString command = positional.isEmpty()
        ? (parser.isSet(hiddenOption) ? QStringLiteral("start") : QStringLiteral("show"))
        : positional.first();
    const QStringList known = { QStringLiteral("start"), QStringLiteral("show"), QStringLiteral("hide"), QStringLiteral("toggle"),
                                QStringLiteral("quit"), QStringLiteral("status"), QStringLiteral("reload-theme") };
    QTextStream out(stdout), err(stderr);
    if (!known.contains(command)) {
        err << "omateams: unknown command '" << command << "'\n";
        return 2;
    }

    QString reply;
    if (command == QLatin1String("start") && sendToRunning(QStringLiteral("status"), &reply))
        return 0;
    if (sendToRunning(command, &reply)) {
        if (!reply.isEmpty())
            out << reply << "\n";
        return 0;
    }
    if (command == QLatin1String("hide") || command == QLatin1String("quit")
        || command == QLatin1String("status") || command == QLatin1String("reload-theme")) {
        if (command == QLatin1String("status"))
            out << "{\"running\": false}\n";
        else
            err << "omateams: not running\n";
        return command == QLatin1String("status") ? 0 : 1;
    }

    // No instance answered: this process becomes it. A stale socket from a
    // crashed instance would otherwise block listen().
    QLocalServer::removeServer(socketPath());
    QLocalServer server;
    if (!server.listen(socketPath())) {
        err << "omateams: cannot listen on " << socketPath() << ": " << server.errorString() << "\n";
        return 1;
    }
    Bridge bridge(&server);

    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty(QStringLiteral("Sys"), &bridge);
    engine.rootContext()->setContextProperty(QStringLiteral("appVersion"), QStringLiteral(OMATEAMS_VERSION));
    engine.setInitialProperties({
        { QStringLiteral("startHidden"), parser.isSet(hiddenOption) },
        { QStringLiteral("startUrl"), parser.value(urlOption) },
    });

    // OMATEAMS_QML_DIR points the host at QML on disk for development; the
    // release binary carries its QML as resources.
    const QString qmlDir = qEnvironmentVariable("OMATEAMS_QML_DIR");
    const QUrl mainUrl = qmlDir.isEmpty()
        ? QUrl(QStringLiteral("qrc:/qml/Main.qml"))
        : QUrl::fromLocalFile(QDir(qmlDir).filePath(QStringLiteral("Main.qml")));
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed, &app, [] { QCoreApplication::exit(1); }, Qt::QueuedConnection);
    engine.load(mainUrl);
    if (engine.rootObjects().isEmpty())
        return 1;
    return app.exec();
}
