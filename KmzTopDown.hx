import haxe.io.*;  // para poder usar Input e BytesOutput, ao invés de haxe.io.Input/BytesOutput
import haxe.zip.Entry in ZipEntry;  // para poder user ZipEntry ao invés de haxe.zip.Entry
import sys.io.File;  // para poder usar File, ao invés de sys.io.File

typedef TopDownDataRecord = {
	idPleito : Int,
	idAgrup : Int,
	idAncora : Int,
	tipoProj : String,
	resAHP : String,
	localProj : String,
	infraProj : String
}

typedef IconsData = {
	codAncora : Dynamic,
	codProjeto : Dynamic,
	categoria : Dynamic,
	categoriaIgnorada : Array<String>,
	source : String
}

class KmzTopDown {
	static function getElementName(xml:Xml) {
		return xml.elementsNamed("name").next().firstChild().nodeValue;
	}

	static function findFolders(xml:Xml){
		var ret = [];
		if(xml.nodeType==Element && xml.nodeName=="Folder")
			ret.push(getElementName(xml)); //"nunca faça isto (sobre next())"
		for (e in xml.elements())
			ret = ret.concat(findFolders(e));
		return ret;
	}

	static function getOrAddFolder(xml:Xml, name:String){
		for (folder in xml.elementsNamed("Folder")){
			var fname=getElementName(folder);
			if (fname==name)
				return folder;

		}

		var folder=Xml.createElement("Folder");
		var folderName=Xml.createElement("name");
		var nameValue=Xml.createPCData(name);

		folderName.addChild(nameValue);
		folder.addChild(folderName);
		xml.addChild(folder);

		return folder;

		// alternativa para criar o folder:
		// var folder = Xml.parse('<Folder><name>$name</name></Folder>');
	}

	static function ensureUtf8(s:String)
	{
		return haxe.Utf8.validate(s) ? s : haxe.Utf8.encode(s);
	}

	static function selectIcon(iconsData:IconsData, pmarkData:TopDownDataRecord){
		var ca = Reflect.field(iconsData.codAncora, Std.string(pmarkData.idAncora));
		var cp = Reflect.field(Reflect.field(iconsData.codProjeto, pmarkData.localProj), pmarkData.infraProj);
		var cc = Reflect.field(iconsData.categoria, pmarkData.resAHP);
		if (ca == null || cp == null || cc == null)
			trace('WARNING faltam ícones para ${pmarkData.idPleito}: $ca (${pmarkData.idAncora}) $cp (${pmarkData.infraProj}) $cc (${pmarkData.resAHP})');
		return '$ca-$cp$cc';
	}

	static function processLabels(xml:Xml, kmzTopDownData:Map<Int, TopDownDataRecord>, iconsData:IconsData,doc:Xml){
		trace('Em ${getElementName(xml)}');
		for (folder in xml.elementsNamed("Folder")){
			$type(folder);
			processLabels(folder,kmzTopDownData,iconsData,doc);
		}
		var rm = [];
		for (pmark in xml.elementsNamed("Placemark")){
			var idPlacemark=getElementName(pmark);
			$type(idPlacemark);
			var data=kmzTopDownData.get(Std.parseInt(idPlacemark));
			if (data==null){
				trace('WARNING falta info para pleito $idPlacemark');
				continue;
			}
			if (Lambda.has(iconsData.categoriaIgnorada, data.resAHP)) {
				trace('WARNING removendo pleito $idPlacemark (resAHP: ${data.resAHP})');
				rm.push(pmark);
				continue;
			}
			var outFolder = getOrAddFolder(doc, data.resAHP);
			var agrupFolder = getOrAddFolder(outFolder, Std.string(data.idAgrup));
			var pleitoFolder = getOrAddFolder(agrupFolder, idPlacemark);
			pleitoFolder.addChild(pmark);
			if (!pmark.elementsNamed("Point").hasNext())
				continue;
			// ref our icon style if possible (if pmark doesn't have a styleUrl yet)
			// else, add our icon style inline
			var icon = selectIcon(iconsData, data);
			if (!pmark.elementsNamed("styleUrl").hasNext())
				pmark.addChild(Xml.parse('<styleUrl>#icons/$icon.png</styleUrl>'));
			else
				pmark.addChild(Xml.parse('<Style><IconStyle><Icon><href>icons/$icon.png</href></Icon></IconStyle></Style>'));
		}
		for (pmark in rm)
			pmark.parent.removeChild(pmark);
	}

	static function createIcons(doc:Xml, out:List<ZipEntry>, iconsData:IconsData){
		var iconsPath = sys.FileSystem.readDirectory(iconsData.source);
		for (path in iconsPath){
			if (!StringTools.endsWith(path.toLowerCase(), ".png"))
				continue;
			var kmzPath = "icons/" + path;
			var style = Xml.parse('<Style id="$kmzPath"><IconStyle><Icon><href>$kmzPath</href></Icon></IconStyle></Style>');
			doc.insertChild(style,1);
			out.add({
				fileName : kmzPath,
				fileTime : Date.now(),
				data : File.getBytes('${iconsData.source}/$path'),
				compressed : false,
				fileSize : 0,
				dataSize :  0,
				crc32 : null
			});
		}
	}

	static function main() {
		// customiza trace() para melhor legibilidade e para que lide automaticamente com !Utf8 no Windows
		haxe.Log.trace = function (msg, ?pos) {
			msg = Std.string(msg);
			// no Windows, remove Utf8 (decodifica para o que o console está usando)
			if (Sys.systemName() == "Windows" && haxe.Utf8.validate(msg))
				msg = haxe.Utf8.decode(msg);
			// já no Linux ou Mac, converte para Utf8 se já não estiver assim
			if (Sys.systemName() != "Windows" && !haxe.Utf8.validate(msg))
				msg = haxe.Utf8.encode(msg);
			// prepara a mensagem
			msg += '   @ ${pos.className}::${pos.methodName} (${pos.fileName}:${pos.lineNumber})\n';
			if (pos.customParams != null)
				msg += pos.customParams.map(function (x) return '\t$x\n');
			// escreve no console (no output de erro)
			Sys.stderr().writeString(msg);
		}

		trace("Welcome, Pookyto!");

		var args = Sys.args(); //mto estúpido!
		trace('Command line arguments: ${args.join(",")}');

		if (args.length < 3)
			throw "Usage: KmzTopDown <data.csv> <icons.json> <kml,kmz> ...";
		var csvPath = args[0];

		var csvData:haxe.io.Input = sys.io.File.read(csvPath, false);
		//var csvData:Input = File.read(csvPath, false);
		//trace(csvData.readLine()); - não usar!!! só para não esquecer!!! não descomentar pq o Jonas explode!!

		var reader = new format.csv.Reader(";");
		reader.reset(null, csvData);

		var kmzTopDownData = new Map();
		for (rec in reader){
			var data = {
				idPleito : Std.parseInt(rec[0]),
				idAgrup : Std.parseInt(rec[1]),
				idAncora : Std.parseInt(rec[2]),
				tipoProj : ensureUtf8(rec[3]),
				resAHP : ensureUtf8(rec[4]),
				localProj : ensureUtf8(rec[5]),
				infraProj : ensureUtf8(rec[6])
			};

			// ignore se não foi possível parsear idPleito em Int
			if (data.idPleito == null) {
				trace('WARNING ignorando linha do csv: ${rec.slice(0,3).join(",")}...');
				continue;
			}

			kmzTopDownData.set(data.idPleito, data);
		}

		var kmlPath = args[2];
		var kmlData:Input = File.read(kmlPath,true);
		var kml = Xml.parse(kmlData.readAll().toString());

		var doc=kml.elementsNamed("kml").next().elementsNamed("Document").next();

		var kmzPath = ~/\.kml$/.replace(kmlPath, "_topDown.kmz");
		var zentries = new List();
		var zoutput = new BytesOutput();
		var zwriter = new haxe.zip.Writer(zoutput);

		trace("Folder Kml elements:\n\t" + findFolders(kml).join("\n\t"));

		var iconsPath = args[1];
		var iconsJson = File.getContent(iconsPath);
		var iconsData:IconsData = haxe.Json.parse(iconsJson);

		createIcons(doc, zentries, iconsData);

		//kml.addChild(Xml.createComment("Eu sou um comentário feliz-Pookyto!"));
		//File.saveContent("temp.kml", kml.toString());

		// não necessário, processLabels já chama getOrAddFolder conforme necessário
		// for (fname in ["Selecionado", "Análise", "Projetos decididos"])
		// 	getOrAddFolder(doc,fname);

		var ancoraFolder=doc.elementsNamed("Folder").next(); //âncora
		var ancoraContents=ancoraFolder.elementsNamed("Folder");

		var tracadoFolder=ancoraContents.next(); //pasta traçado
		var labelsFolder=ancoraContents.next(); //pasta labels

		processLabels(labelsFolder,kmzTopDownData,iconsData,doc);
		// processLabels(tracadoFolder,kmzTopDownData,iconsData,doc);

		// escreve o doc.kml no kmz de saída
		var docBytes = Bytes.ofString(kml.toString());
		zentries.add({
			fileName : "doc.kml",
			fileTime : Date.now(),
			data : docBytes,
			compressed : false,
			fileSize : 0,
			dataSize :  0,
			crc32 : null
		});

		// escreve o kmz
		zwriter.write(zentries);
		File.saveBytes(kmzPath, zoutput.getBytes());
		File.saveBytes("temp.kml", docBytes);
	}
}

