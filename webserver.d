import std.algorithm;
import std.array;
import std.conv;
import std.exception;
import std.file;
import std.format;
import std.functional;
import std.regex;
import std.string;

import ae.net.asockets;
import ae.net.http.common;
import ae.net.http.responseex;
import ae.net.http.server;
import ae.net.shutdown;
import ae.sys.d.cache;
import ae.sys.git;
import ae.sys.log;
import ae.utils.exception;
import ae.utils.meta;
import ae.utils.mime;
import ae.utils.regex;
import ae.utils.sini;
import ae.utils.textout;
import ae.utils.xmllite;

struct Config
{
	string addr;
	ushort port = 80;
}
immutable Config config;

StringBuffer html;
Logger log;

Repository cache;
Repository.ObjectReader objectReader;

void onRequest(HttpRequest request, HttpServerConnection conn)
{
	conn.sendResponse(handleRequest(request, conn));
}

HttpResponse handleRequest(HttpRequest request, HttpServerConnection conn)
{
	auto response = new HttpResponseEx();
	auto status = HttpStatusCode.OK;
	string title;
	html.clear();

	try
	{
		auto pathStr = request.resource.findSplit("?")[0];
		enforce(pathStr.startsWith('/'), "Invalid path");
		auto path = pathStr[1..$].split("/");
		if (!path.length) path = [""];

		pathSwitch:
		switch (path[0])
		{
			case "":
				title = "Index";
				showIndex();
				break;
			case "results":
				title = "Test result";
				enforce(path.length > 3, "Bad path");
				enforce(path[1].match(re!`^[0-9a-f]{40}$`), "Bad base commit");
				enforce(path[2].match(re!`^[0-9a-f]{40}$`) || path[2] == "!base", "Bad pull commit");

				auto testDir = "results/%s/%s/".format(path[1], path[2]);
				enforce(testDir.exists, "No such commit");

				auto action = path[3];
				switch (action)
				{
					case "":
						showResult(testDir);
						break;
					case "build.log":
						return response.serveFile(pathStr[1..$], "");
					case "file":
					{
						auto buildID = readText(testDir ~ "buildid.txt");
						return response.redirect("/artifact/" ~ buildID ~ "/" ~ path[4..$].join("/"));
					}
					case "diff":
					{
						auto buildID = readText(testDir ~ "buildid.txt");
						auto baseBuildID = readText(testDir ~ "../!base/buildid.txt");
						return response.redirect("/diff/" ~ baseBuildID ~ "/" ~ buildID ~ "/" ~ path[4..$].join("/"));
					}
					default:
						throw new Exception("Unknown action");
				}
				break;
			case "artifact":
			{
				enforce(path.length >= 2, "Bad path");
				auto refName = GitCache.refPrefix ~ path[1];
				auto commitObject = objectReader.read(refName);
				auto obj = objectReader.read(commitObject.parseCommit().tree);
				foreach (dirName; path[2..$])
				{
					auto tree = obj.parseTree();
					if (dirName == "")
					{
						title = "Artifact storage directory listing";
						showDirListing(tree);
						break pathSwitch;
					}
					auto index = tree.countUntil!(entry => entry.name == dirName);
					enforce(index >= 0, "Name not in tree: " ~ dirName);
					obj = objectReader.read(tree[index].hash);
				}
				enforce(obj.type == "blob", "Invalid object type");
				return response.serveData(Data(obj.data), guessMime(path[$-1]));
			}
			case "diff":
			{
				enforce(path.length >= 4, "Bad path");
				auto refA = GitCache.refPrefix ~ path[1];
				auto refB = GitCache.refPrefix ~ path[2];
				return response.serveText(cache.query(["diff", refA, refB, "--", path[3..$].join("/")]));
			}
			case "static":
				return response.serveFile(pathStr[1..$], "web/");
			case "robots.txt":
				return response.serveText("User-agent: *\nDisallow: /");
			default:
				throw new Exception("Unknown resource");
		}
	}
	catch (CaughtException e)
		return response.writeError(HttpStatusCode.InternalServerError, e.toString());

	auto vars = [
		"title" : title,
		"content" : cast(string) html.get(),
	];

	response.serveData(response.loadTemplate("web/skel.htt", vars));
	response.setStatus(status);
	return response;
}

void showIndex()
{
	html.put("This is the DAutoTest web service.");
}

void showDirListing(GitObject.TreeEntry[] entries)
{
	html.put(
		`<ul class="dirlist">`
		`<li>       <a href="../">..</a></li>`
	);
	foreach (entry; entries)
	{
		auto name = encodeEntities(entry.name) ~ (entry.mode & octal!40000 ? `/` : ``);
		html.put(
			`<li>`, "%06o".format(entry.mode), ` <a href="`, name, `">`, name, `</a></li>`
		);
	}
	html.put(
		`</ul>`
	);
}

void showResult(string testDir)
{
	string tryReadText(string fileName, string def = null) { return fileName.exists ? fileName.readText : def; }

	auto result = tryReadText(testDir ~ "result.txt", "Unknown\n(unknown)").splitLines();
	auto info = tryReadText(testDir ~ "info.txt", "\n0").splitLines();

	html.put(
		`<table>`
		`<tr><td>Component</td><td>`, info[0], `</td></tr>`
		`<tr><td>Pull request</td><td><a href="`, info[2], `">#`, info[1], `</a></td></tr>`
		`<tr><td>Status</td><td>`, result[0], `</td></tr>`
		`<tr><td>Details</td><td>`, result[1], `</td></tr>`
	//	`<tr><td>Build log</td><td><pre>`, tryReadText(testDir ~ "build.log").encodeEntities(), `</pre></td></tr>`
		`<tr><td>Build log</td><td><a href="build.log">View</a></td></tr>`
		`<tr><td>Files</td><td><a href="file/web/index.html">Main page</a> &middot; <a href="file/web/">All files</a></td></tr>`
	);
	if (result[0] == "success" && exists(testDir ~ "numstat.txt"))
	{
		auto lines = readText(testDir ~ "numstat.txt").strip.splitLines.map!(line => line.split('\t')).array;
		int additions, deletions, maxChanges;
		foreach (line; lines)
		{
			if (line[0] == "-")
				additions++, deletions++;
			else
			{
				additions += line[0].to!int;
				deletions += line[1].to!int;
				maxChanges = max(maxChanges, line[0].to!int + line[1].to!int);
			}
		}

		html.put(
			`<tr><td>Changes</td><td>`
			`<table class="changes">`
		);
		if (!lines.length)
			html.put(`(no changes)`);
		auto changeWidth = min(100.0 / maxChanges, 5.0);
		foreach (line; lines)
		{
			auto fn = line[2];
			if (fn.startsWith("digger-"))
				continue;
			html.put(`<tr><td>`, encodeEntities(fn), `</td><td>`);
			if (line[0] == "-")
				html.put(`(binary file)`);
			else
			{
				html.put(`<div class="additions" style="width:%5.3f%%" title="%s addition%s"></div>`.format(line[0].to!int * changeWidth, line[0], line[0]=="1" ? "" : "s"));
				html.put(`<div class="deletions" style="width:%5.3f%%" title="%s deletion%s"></div>`.format(line[1].to!int * changeWidth, line[1], line[1]=="1" ? "" : "s"));
			}
			html.put(
				`</td>`
				`<td>`
					`<a href="file/`, encodeEntities(fn), `">Old</a> `
					`<a href="../!base/file/`, encodeEntities(fn), `">New</a> `
					`<a href="diff/`, encodeEntities(fn), `">Diff</a>`
				`</td>`
				`</tr>`
			);
		}
		html.put(
			`</table>`
			`</td></tr>`
		);
	}
	html.put(
		`</table>`
	);
}

string ansiToHtml(string ansi)
{
	return ansi
		.I!(s => `<span>` ~ s ~ `</span>`)
		.replace("\x1B[m"  , `</span><span>`)
		.replace("\x1B[31m", `</span><span class="ansi-1">`)
		.replace("\x1B[32m", `</span><span class="ansi-2">`)
	;
}

shared static this()
{
	config = loadIni!Config("webserver.ini");
}

void main()
{
	log = createLogger("WebServer");

	cache = Repository("work/cache-git/v2/");
	objectReader = cache.createObjectReader();

	auto server = new HttpServer();
	server.log = log;
	server.handleRequest = toDelegate(&onRequest);
	server.listen(config.port, config.addr);
	addShutdownHandler({ server.close(); });

	socketManager.loop();
}