#pragma once

#include <QFileSystemWatcher>
#include <QHash>
#include <QLocalServer>
#include <QObject>
#include <QPointer>
#include <QString>
#include <QStringList>
#include <QWindow>

class QLocalSocket;
class QProcess;

// The small native surface the QML host needs and plain QML cannot provide:
// files, a directory watch for the Omarchy theme, child processes for
// notify-send/hyprctl, and the local socket the bar widget and the CLI use
// to talk to the running instance.
class Bridge : public QObject {
    Q_OBJECT
public:
    explicit Bridge(QLocalServer *server, QObject *parent = nullptr);

    Q_INVOKABLE QString home() const;
    Q_INVOKABLE QString runtimeDir() const;
    Q_INVOKABLE QString configDir() const;
    Q_INVOKABLE QString stateDir() const;
    Q_INVOKABLE QString env(const QString &name) const;
    Q_INVOKABLE int pid() const;

    Q_INVOKABLE bool exists(const QString &path) const;
    Q_INVOKABLE QString readFile(const QString &path) const;
    Q_INVOKABLE bool writeFile(const QString &path, const QString &text);
    Q_INVOKABLE bool removeFile(const QString &path);
    Q_INVOKABLE void watch(const QString &path);

    Q_INVOKABLE void run(const QString &program, const QStringList &arguments);
    Q_INVOKABLE int runCapture(const QString &program, const QStringList &arguments);
    Q_INVOKABLE void reply(int connection, const QString &text);
    Q_INVOKABLE void watchExposure(QWindow *window);

signals:
    void fileChanged(const QString &path);
    void processFinished(int id, int exitCode, const QString &output);
    void command(int connection, const QString &line);
    void exposed(QWindow *window);

protected:
    bool eventFilter(QObject *watched, QEvent *event) override;

private:
    void acceptConnection();
    void readCommand(QLocalSocket *socket, int id);

    QLocalServer *m_server;
    QFileSystemWatcher m_watcher;
    QHash<int, QPointer<QLocalSocket>> m_connections;
    int m_nextConnection = 1;
    int m_nextProcess = 1;
};
